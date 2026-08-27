#!/usr/bin/env bash
set -euo pipefail

DATA_DIR=/data
TS3_BIN=/opt/ts3/ts3server
RENDERED_INI=/run/ts3server.ini

log() { printf '[entrypoint] %s\n' "$*"; }

# --- Docker HEALTHCHECK entrypoint (runs before any privilege work) ----------
# Defaults to the SSH query port; override TS3_HEALTHCHECK_PORT for a custom
# protocol/port (e.g. raw on 10011) or a custom ini.
if [[ "${1:-}" == "healthcheck" ]]; then
  exec nc -z 127.0.0.1 "${TS3_HEALTHCHECK_PORT:-${TS3_QUERY_SSH_PORT:-10022}}"
fi

# --- Optional PUID/PGID remap (linuxserver-style) ----------------------------
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
if [[ "$(id -g ts)" != "$PGID" ]]; then groupmod -o -g "$PGID" ts; fi
if [[ "$(id -u ts)" != "$PUID" ]]; then usermod  -o -u "$PUID" ts; fi

# --- Persistent state on the volume ------------------------------------------
# Detect a fresh install before the server creates its database.
FIRST_BOOT=0
[[ -f "$DATA_DIR/ts3server.sqlitedb" ]] || FIRST_BOOT=1

# Decide up front whether a full recursive chown is needed (top-level owner
# wrong). Capture this BEFORE we touch ownership below.
NEED_RECURSIVE=0
[[ "$(stat -c '%u:%g' "$DATA_DIR")" == "$PUID:$PGID" ]] || NEED_RECURSIVE=1

mkdir -p "$DATA_DIR/logs" "$DATA_DIR/crashdumps"

# Ensure 127.0.0.1 is exempt from query flood protection so our healthcheck
# (and local tooling) never gets auto-banned. Operators add their own IPs here.
ALLOWLIST="$DATA_DIR/query_ip_allowlist.txt"
if [[ ! -f "$ALLOWLIST" ]]; then
  printf '127.0.0.1\n' > "$ALLOWLIST"
fi

if [[ "$NEED_RECURSIVE" == 1 ]]; then
  log "fixing ownership of $DATA_DIR -> $PUID:$PGID"
  chown -R ts:ts "$DATA_DIR"
else
  # Top-level already correct (e.g. a pre-chowned bind mount), so the recursive
  # chown is skipped — but still own the paths we just created as root, or the
  # unprivileged server can't write its logs/allowlist.
  chown ts:ts "$DATA_DIR/logs" "$DATA_DIR/crashdumps" "$ALLOWLIST"
fi

# --- Config ------------------------------------------------------------------
# TS3 never rewrites its ini (runtime state lives in the SQLite DB and
# licensekey.dat), so we regenerate it from the environment on every start and
# keep it off the volume to avoid clobbering operator hand-edits. Operators who
# want full control can mount their own ini and point TS3SERVER_INI at it.
if [[ -n "${TS3SERVER_INI:-}" ]]; then
  if [[ ! -f "$TS3SERVER_INI" ]]; then
    log "ERROR: TS3SERVER_INI=$TS3SERVER_INI does not exist (mount it into the container)"
    exit 1
  fi
  log "using operator-provided ini: $TS3SERVER_INI"
  INI_FILE="$TS3SERVER_INI"
else
  INI_FILE="$RENDERED_INI"
  log "rendering ini -> $INI_FILE"
  cat > "$INI_FILE" <<EOF
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
  chown ts:ts "$INI_FILE"
fi

# --- Launch ------------------------------------------------------------------
# CWD=/data so ts3server.sqlitedb and ssh_host_rsa_key land on the volume.
# LD_LIBRARY_PATH / BOX64_DYNAREC_STRONGMEM / TS3SERVER_LICENSE come from the
# image env and are inherited through gosu.
LAUNCH_ARGS=("inifile=$INI_FILE")
if [[ -n "${TS3_QUERY_ADMIN_PASSWORD:-}" ]]; then
  if [[ "$FIRST_BOOT" == 1 ]]; then
    # Only seed on the very first boot; passing it on every start would reset the
    # password each time and silently revert any later change. Note it is briefly
    # visible in the process list this once.
    log "seeding serveradmin password (first boot only)"
    LAUNCH_ARGS+=("serveradmin_password=${TS3_QUERY_ADMIN_PASSWORD}")
  else
    log "TS3_QUERY_ADMIN_PASSWORD is set but ignored — database already exists"
  fi
fi

log "starting TeamSpeak 3 server (box64) ..."
cd "$DATA_DIR"
exec gosu ts box64 "$TS3_BIN" "${LAUNCH_ARGS[@]}"
