# ts3-server-arm64

A small, hardened Docker image that runs the **TeamSpeak 3 server on arm64**
(Raspberry Pi, Ampere, Graviton) by executing the official x86-64 binary under
[box64](https://github.com/ptitSeb/box64). TeamSpeak has never shipped an ARM
build of the server, and box64 is the fastest way to run the x86 one.

- **Stable SSH ServerQuery host key.** It lives on the `/data` volume, so tools
  that pin the host key keep working across restarts and recreates.
- **Pinned and verified.** box64 is built from a pinned, commit-checked tag and
  the TeamSpeak tarball is checked against a pinned SHA256. No proprietary
  binaries live in this repo.
- **Safe defaults.** The server runs as a non-root user, only SSH ServerQuery is
  enabled, config comes from env vars, and a healthcheck is built in.
- **No surprise updates.** Nothing is downloaded on container start; TeamSpeak
  upgrades arrive as a reviewable PR and a new image tag.

## Quick start

```yaml
# docker-compose.yml
services:
  teamspeak:
    image: ghcr.io/ithilias/ts3-server-arm64:latest
    container_name: teamspeak
    restart: unless-stopped
    init: true                # clean signals + zombie reaping
    stop_grace_period: 30s    # let SQLite flush before SIGKILL
    security_opt:
      - no-new-privileges:true
    environment:
      TZ: Europe/Berlin
      # TS3_QUERY_ADMIN_PASSWORD: change-me   # otherwise a token is printed on first boot
    ports:
      - "9987:9987/udp"       # voice
      - "30033:30033/tcp"     # file transfer
      - "10022:10022/tcp"     # SSH ServerQuery: firewall this to trusted sources
    volumes:
      - ts3-data:/data

volumes:
  ts3-data:
```

```sh
docker compose up -d
docker compose logs -f teamspeak   # first boot prints the admin token and privilege key
```

Connect a TeamSpeak client on `9987/udp` and claim admin with the privilege key
from the logs. If you clone the repo instead, its `docker-compose.yml` reads a
`.env` file (see [`.env.example`](.env.example)) and can build locally with
`build: .`.

## Configuration

The server's ini is generated from these variables on every start. TeamSpeak
keeps its state in the database, so regenerating it loses nothing.

| Variable | Default | Purpose |
|---|---|---|
| `TS3_VOICE_PORT` | `9987` | Voice UDP port (only for a new server, see below) |
| `TS3_FILETRANSFER_PORT` | `30033` | File transfer TCP port |
| `TS3_QUERY_SSH_PORT` | `10022` | SSH ServerQuery port |
| `TS3_QUERY_PROTOCOLS` | `ssh` | ServerQuery protocols; keep `ssh` only |
| `TS3_HEALTHCHECK_PORT` | SSH port | Port the healthcheck probes; without `ssh`: raw `10011`, http `10080`, https `10443` |
| `TS3_QUERY_ADMIN_PASSWORD` | unset | `serveradmin` password, applied on first boot only |
| `TS3_QUERY_ADMIN_PASSWORD_FILE` | unset | Same, read from a file such as a Docker secret |
| `TS3SERVER_INI` | unset | Use your own ini instead of the generated one |
| `PUID` / `PGID` | `1000` | uid/gid the server runs as |
| `TZ` | UTC | Timezone for log timestamps |

- Invalid ports, ids or protocols stop the container with a clear error.
- TeamSpeak stores the voice port in its database when it creates the virtual
  server. On an existing install, changing `TS3_VOICE_PORT` alone has no effect;
  change the port in TeamSpeak too.
- The admin password reaches TeamSpeak through the generated ini (mode 0600),
  not the command line. (With your own `TS3SERVER_INI` it goes on the command
  line for the first boot.) Prefer the `_FILE` variant so it also stays out of
  `docker inspect`:

  ```yaml
  services:
    teamspeak:
      environment:
        TS3_QUERY_ADMIN_PASSWORD_FILE: /run/secrets/ts3_admin_password
      secrets: [ts3_admin_password]
  secrets:
    ts3_admin_password:
      file: ./ts3_admin_password.txt
  ```
- The box64 settings baked into the image (`BOX64_DYNAREC_STRONGMEM=4`,
  `BOX64_DYNAREC_BIGBLOCK=0`) can be overridden like any other variable. They
  exist for stability; the rationale is in the [`Dockerfile`](Dockerfile).

## Your data

Everything lives in `/data`: `ts3server.sqlitedb` (server, channels,
permissions, identities), `files/` (file transfers), `ssh_host_rsa_key`,
`licensekey.dat` (if any), the `query_ip_*.txt` lists, `logs/` and
`crashdumps/`. When the container starts as root (the default), the entrypoint
gives any file in `/data` that the server user doesn't own to `PUID:PGID`. On a
bind mount that means changing `PUID`/`PGID` re-owns every file under it on the
next start.

**Backup.** Stop the container first so SQLite is consistent:

```sh
docker compose stop teamspeak
sudo tar czf ts3-backup-$(date +%F).tgz -C /var/lib/docker/volumes/<project>_ts3-data/_data .
docker compose start teamspeak
```

**Upgrade and rollback.** `docker compose pull && docker compose up -d`. To roll
back, pin the previous `:vX.Y.Z` or dated `:YYYYMMDD` tag and run `up -d` again.
Restore the backup too if the newer TeamSpeak already migrated the database.

**Importing an existing server.** Copy the old files into the volume before the
first start:

```sh
NEW=/var/lib/docker/volumes/<project>_ts3-data/_data   # or your bind mount
sudo cp    /path/to/old/ts3server.sqlitedb "$NEW"/
sudo cp -r /path/to/old/files              "$NEW"/ 2>/dev/null || true
sudo cp    /path/to/old/licensekey.dat     "$NEW"/ 2>/dev/null || true
sudo cp    /path/to/old/ssh_host_rsa_key   "$NEW"/   # keeps the SSH fingerprint
docker compose up -d
```

Copy the host key file rather than scraping it with `ssh-keyscan`. TeamSpeak's
older SSH stack closes the probe. Clients connect fine as long as they offer
the `rsa-sha2-512` host key algorithm.

## Hardening

- Never enable or publish the plaintext raw query (`10011`) on a public network.
- Firewall the SSH ServerQuery port to the sources that need it, and add those
  IPs to `/data/query_ip_allowlist.txt` to exempt them from flood protection.
  (`127.0.0.1` is seeded so the healthcheck is never banned.)
- To go beyond `no-new-privileges`, add `cap_drop: [ALL]` with
  `cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE]`. That is what the entrypoint
  needs to fix ownership and drop privileges. Alternatively, start the container
  with `user: "1000:1000"` and make sure `/data` is writable by that uid.

## Known quirk: accounting "Bad file descriptor" restarts

```
ERROR |Accounting | |failed to register local accounting service: Bad file descriptor
```

A long-standing TeamSpeak quirk around its `/dev/shm` accounting service, also
seen on native x86 and under QEMU. It is benign: the server exits cleanly and
`restart: unless-stopped` brings it back in about a second. Under box64 it
happens more often than under QEMU; if it becomes disruptive, a QEMU-based
image avoids it at a higher CPU cost. A real crash looks different: it leaves a
core dump in `/data/crashdumps`.

## Building and maintaining

```sh
docker build -t ts3-server-arm64 .   # on any arm64 host, no emulation needed
```

Releases, the weekly rebuild, automated TeamSpeak updates and version bumps are
described in [MAINTAINING.md](MAINTAINING.md).

## License

This repo's packaging (Dockerfile, entrypoint, workflows, compose, docs) is
[MIT](LICENSE). It contains no TeamSpeak code; the server is downloaded at
build time and remains under the
[TeamSpeak license](https://www.teamspeak.com/en/privacy-and-terms/). Building
or running the image means you accept it (the image sets
`TS3SERVER_LICENSE=accept`).
