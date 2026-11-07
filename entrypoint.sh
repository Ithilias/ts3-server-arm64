#!/usr/bin/env bash
set -euo pipefail

DATA_DIR=/data
TS3_BIN=/opt/ts3/ts3server

log() { printf '[entrypoint] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

# --- Docker HEALTHCHECK entrypoint (runs before any privilege work) ----------
# Probes the SSH query port if ssh is enabled, otherwise the default port of
# the first other enabled protocol (raw 10011, http 10080, https 10443).
# Override TS3_HEALTHCHECK_PORT for anything else (e.g. a custom ini).
if [[ "${1:-}" == "healthcheck" ]]; then
  protos=",${TS3_QUERY_PROTOCOLS:-ssh},"
  if [[ -n "${TS3_HEALTHCHECK_PORT:-}" ]]; then port="$TS3_HEALTHCHECK_PORT"
  elif [[ "$protos" == *,ssh,* ]];   then port="${TS3_QUERY_SSH_PORT:-10022}"
  elif [[ "$protos" == *,raw,* ]];   then port=10011
  elif [[ "$protos" == *,http,* ]];  then port=10080
  elif [[ "$protos" == *,https,* ]]; then port=10443
  else port="${TS3_QUERY_SSH_PORT:-10022}"
  fi
  exec nc -z 127.0.0.1 "$port"
fi

# --- Validate env --------------------------------------------------------------
# These end up in the ini and on the command line; fail loudly on typos instead
# of letting TS3 silently fall back to a default (or bind something unexpected).
check_port() {
  local name="$1" v="${!1:-}"
  [[ -z "$v" ]] && return 0
  if ! [[ "$v" =~ ^[0-9]{1,5}$ ]] || (( 10#$v < 1 || 10#$v > 65535 )); then
    die "$name must be a port number (1-65535), got: '$v'"
  fi
}
check_id() {
  local name="$1" v="${!1:-}"
  [[ -z "$v" ]] && return 0
  [[ "$v" =~ ^[0-9]+$ ]] || die "$name must be a numeric id, got: '$v'"
}
for v in TS3_VOICE_PORT TS3_FILETRANSFER_PORT TS3_QUERY_SSH_PORT TS3_HEALTHCHECK_PORT; do
  check_port "$v"
done
check_id PUID
check_id PGID
if [[ -n "${TS3_QUERY_PROTOCOLS:-}" ]] \
   && ! [[ "$TS3_QUERY_PROTOCOLS" =~ ^(raw|ssh|http|https)(,(raw|ssh|http|https))*$ ]]; then
  die "TS3_QUERY_PROTOCOLS must be a comma-separated list of raw,ssh,http,https, got: '$TS3_QUERY_PROTOCOLS'"
fi

# --- serveradmin password -----------------------------------------------------
# Read it (from env or a Docker secret file), then drop it from the environment
# so it isn't inherited by the long-running server process.
ADMIN_PASSWORD="${TS3_QUERY_ADMIN_PASSWORD:-}"
if [[ -n "${TS3_QUERY_ADMIN_PASSWORD_FILE:-}" ]]; then
  [[ -r "$TS3_QUERY_ADMIN_PASSWORD_FILE" ]] \
    || die "TS3_QUERY_ADMIN_PASSWORD_FILE=$TS3_QUERY_ADMIN_PASSWORD_FILE is not readable"
  [[ -n "$ADMIN_PASSWORD" ]] && log "both TS3_QUERY_ADMIN_PASSWORD and _FILE are set; using _FILE"
  ADMIN_PASSWORD="$(<"$TS3_QUERY_ADMIN_PASSWORD_FILE")"
fi
unset TS3_QUERY_ADMIN_PASSWORD TS3_QUERY_ADMIN_PASSWORD_FILE

# Detect a fresh install before the server creates its database.
FIRST_BOOT=0
[[ -f "$DATA_DIR/ts3server.sqlitedb" ]] || FIRST_BOOT=1

# --- Privileged setup (skipped when the container is started as non-root) -----
if [[ "$(id -u)" == 0 ]]; then
  RENDERED_INI=/run/ts3server.ini

  # Optional PUID/PGID remap (linuxserver-style).
  PUID="${PUID:-1000}"
  PGID="${PGID:-1000}"
  if [[ "$(id -g ts)" != "$PGID" ]]; then groupmod -o -g "$PGID" ts; fi
  if [[ "$(id -u ts)" != "$PUID" ]]; then usermod  -o -u "$PUID" ts; fi

  # /data is writable by the server user, so anything in it may have been
  # replaced since the last start. Never follow a symlink as root: refuse the
  # paths we create/write, and chown with -h (find never follows links).
  ALLOWLIST="$DATA_DIR/query_ip_allowlist.txt"
  for p in "$DATA_DIR/logs" "$DATA_DIR/crashdumps" "$ALLOWLIST"; do
    [[ -L "$p" ]] && die "$p is a symlink; refusing to touch it as root (remove it and restart)"
  done
  mkdir -p "$DATA_DIR/logs" "$DATA_DIR/crashdumps"

  # Ensure 127.0.0.1 is exempt from query flood protection so our healthcheck
  # (and local tooling) never gets auto-banned. Operators add their own IPs here.
  if [[ ! -e "$ALLOWLIST" ]]; then
    printf '127.0.0.1\n' > "$ALLOWLIST"
  fi

  # Fix ownership of anything in /data the server user doesn't own (e.g. files
  # imported as root). Only touches mismatches, so it's cheap on later starts.
  # Not fatal: some paths can't be chowned (NFS root_squash, unmapped uids).
  fixed="$(find "$DATA_DIR" -xdev \( ! -user ts -o ! -group ts \) -print -exec chown -h ts:ts {} + | wc -l)" \
    || log "WARNING: could not fix ownership of some paths in $DATA_DIR (see errors above)"
  [[ "${fixed:-0}" == 0 ]] || log "fixed ownership of $fixed path(s) in $DATA_DIR -> $PUID:$PGID"

  RUN_AS=(gosu ts)
else
  # Started with `user:` / --user: no remap or chown possible. The operator is
  # responsible for /data being writable by this uid.
  log "running as uid $(id -u) (not root): skipping PUID/PGID remap and ownership fixes"
  [[ -w "$DATA_DIR" ]] || die "$DATA_DIR is not writable by uid $(id -u)"
  mkdir -p "$DATA_DIR/logs" "$DATA_DIR/crashdumps"
  [[ -e "$DATA_DIR/query_ip_allowlist.txt" ]] || printf '127.0.0.1\n' > "$DATA_DIR/query_ip_allowlist.txt"
  RENDERED_INI="${TMPDIR:-/tmp}/ts3server.ini"
  RUN_AS=()
fi

# --- Config ------------------------------------------------------------------
# TS3 never rewrites its ini (runtime state lives in the SQLite DB and
# licensekey.dat), so we regenerate it from the environment on every start and
# keep it off the volume to avoid clobbering operator hand-edits. Operators who
# want full control can mount their own ini and point TS3SERVER_INI at it.
if [[ -n "${TS3SERVER_INI:-}" ]]; then
  if [[ ! -f "$TS3SERVER_INI" ]]; then
    die "TS3SERVER_INI=$TS3SERVER_INI does not exist (mount it into the container)"
  fi
  log "using operator-provided ini: $TS3SERVER_INI"
  INI_FILE="$TS3SERVER_INI"
else
  INI_FILE="$RENDERED_INI"
  log "rendering ini -> $INI_FILE"
  # Always 0600 (it may get the admin password below); recreate it so the mode
  # applies even if a previous start left a file behind.
  rm -f "$INI_FILE"
  (umask 077; cat > "$INI_FILE") <<EOF
machine_id=
default_voice_port=${TS3_VOICE_PORT:-9987}
voice_ip=0.0.0.0
filetransfer_port=${TS3_FILETRANSFER_PORT:-30033}
filetransfer_ip=0.0.0.0
query_protocols=${TS3_QUERY_PROTOCOLS:-ssh}
query_ssh_ip=0.0.0.0
query_ssh_port=${TS3_QUERY_SSH_PORT:-10022}
query_ssh_rsa_host_key=/data/ssh_host_rsa_key
query_ip_allowlist=/data/query_ip_allowlist.txt
query_ip_denylist=/data/query_ip_denylist.txt
dbplugin=ts3db_sqlite3
dbpluginparameter=
dbsqlpath=/opt/ts3/sql/
dbsqlcreatepath=create_sqlite/
dbclientkeepdays=30
logpath=/data/logs/
serverquerydocs_path=/opt/ts3/serverquerydocs/
licensepath=/data/
EOF
  if [[ "$(id -u)" == 0 ]]; then chown ts:ts "$INI_FILE"; fi
fi

# --- Launch ------------------------------------------------------------------
# CWD=/data so ts3server.sqlitedb and ssh_host_rsa_key land on the volume.
# LD_LIBRARY_PATH / BOX64_DYNAREC_STRONGMEM / TS3SERVER_LICENSE come from the
# image env and are inherited through gosu.
LAUNCH_ARGS=("inifile=$INI_FILE")
if [[ -n "$ADMIN_PASSWORD" ]]; then
  if [[ "$FIRST_BOOT" == 1 ]]; then
    # Only seed on the very first boot; passing it on every start would reset the
    # password each time and silently revert any later change.
    if [[ "$ADMIN_PASSWORD" == *$'\n'* || "$ADMIN_PASSWORD" == *$'\r'* ]]; then
      die "the serveradmin password must not contain line breaks"
    fi
    if [[ "$INI_FILE" == "$RENDERED_INI" ]]; then
      # TS3 reads it from the ini too: keep it in our rendered file (0600, the
      # next start re-renders it without the password) rather than on the
      # command line, where every host user could read it via `ps`.
      printf 'serveradmin_password=%s\n' "$ADMIN_PASSWORD" >> "$INI_FILE"
      log "seeding serveradmin password via the rendered ini (first boot only)"
    else
      # Operator-provided ini: don't write to it, fall back to the command line.
      log "seeding serveradmin password on the command line (first boot only; visible in ps until the next restart)"
      LAUNCH_ARGS+=("serveradmin_password=${ADMIN_PASSWORD}")
    fi
  else
    log "serveradmin password is set but ignored: database already exists"
  fi
fi
unset ADMIN_PASSWORD

log "starting TeamSpeak 3 server (box64) ..."
cd "$DATA_DIR"
exec "${RUN_AS[@]}" box64 "$TS3_BIN" "${LAUNCH_ARGS[@]}"
