# ts3-server-arm64

A small, hardened Docker image that runs the **TeamSpeak 3 server on arm64** by
executing the official 64-bit x86 binary under
[box64](https://github.com/ptitSeb/box64).

TeamSpeak has never shipped a native ARM build of the TS3 *server*, so running
it on arm64 (Ampere/Graviton VPSes, Raspberry Pi, etc.) means emulating the x86
binary — and box64 running the amd64 build is the fastest, best-supported way to
do that. This image keeps that setup lean, reproducible, and safe by default.

## Highlights

- **Stable SSH ServerQuery host key.** The server's `query_ssh_rsa_host_key`
  lives on the mounted `/data` volume, so it survives restarts and container
  recreates. Tools and web panels that pin the ServerQuery host key don't break
  on a regenerated key — a common, annoying failure mode of ephemeral setups.
- **Pinned & verified builds.** box64 is built from a pinned source tag, and the
  TeamSpeak server is downloaded at build time from a pinned version and checked
  against a pinned SHA256 — the build fails on any mismatch. No proprietary
  binaries are committed to this repo.
- **Lean & safe.** arm64-only, no init-system or multi-arch machinery. Runs as a
  non-root user, ships a healthcheck, and generates its config from env vars.
- **No surprise updates.** The TeamSpeak version is pinned; upgrades are a
  deliberate, reviewable step (see [Automation](#automation)) — never an
  unattended download on container start.

## Quick start

Drop this into a `docker-compose.yml` and run `docker compose up -d`:

```yaml
services:
  teamspeak:
    image: ghcr.io/ithilias/ts3-server-arm64:latest
    container_name: teamspeak
    restart: unless-stopped
    init: true                # clean signals + zombie reaping
    stop_grace_period: 30s    # let SQLite flush before SIGKILL
    ports:
      - "9987:9987/udp"       # voice
      - "30033:30033/tcp"     # file transfer
      - "10022:10022/tcp"     # SSH ServerQuery — firewall this to trusted sources
    environment:
      TZ: Europe/Berlin
      # TS3_QUERY_ADMIN_PASSWORD: change-me   # otherwise a token is printed on first boot
    volumes:
      - ts3-data:/data

volumes:
  ts3-data:
```

```sh
docker compose up -d
docker compose logs -f teamspeak   # first boot prints the ServerQuery admin token / privilege key
```

Then connect a TeamSpeak client to the host on `9987/udp` and claim admin with
the privilege key from the logs.

All state (database, logs, file transfers, the SSH host key) persists in the
`ts3-data` volume mounted at `/data`, so restarts and recreates keep your server
— including a **stable ServerQuery host key**.

> **Cloning the repo instead?** It ships this same `docker-compose.yml` plus a
> `.env.example`; copy it to `.env` to set variables there, or just run
> `docker compose up -d`. To build the image locally rather than pull it, set
> `build: .` in the compose file.

## Configuration

Config is generated into `/run/ts3server.ini` from environment variables on
every start. TeamSpeak keeps runtime state in the SQLite database (not the ini),
so regenerating it is lossless. See [`.env.example`](.env.example):

| Variable | Default | Purpose |
|---|---|---|
| `TS3_VOICE_PORT` | `9987` | Voice UDP port |
| `TS3_FILETRANSFER_PORT` | `30033` | File transfer TCP port |
| `TS3_QUERY_SSH_PORT` | `10022` | SSH ServerQuery port |
| `TS3_QUERY_PROTOCOLS` | `ssh` | ServerQuery protocols (keep `ssh` only) |
| `TS3_HEALTHCHECK_PORT` | = SSH port | TCP port the healthcheck probes; override for a custom protocol/ini |
| `TS3_QUERY_ADMIN_PASSWORD` | — | Seed `serveradmin` password (first boot only; ignored once the DB exists) |
| `TS3SERVER_INI` | — | Path to your own ini; bypasses generation |
| `PUID` / `PGID` | `1000` | Run as a specific host uid/gid |
| `TZ` | image default | Timezone for log timestamps |

Want full manual control? Mount your own ini into `/data` and set
`TS3SERVER_INI=/data/ts3server.ini`.

## Importing an existing TeamSpeak server

To move an existing TS3 server onto this image, seed the `/data` volume with the
old server's files before first start (adjust the target to your volume mount):

```sh
NEW=/var/lib/docker/volumes/ts3-server-arm64_ts3-data/_data   # or your bind mount
sudo cp    /path/to/old/ts3server.sqlitedb   "$NEW"/
sudo cp -r /path/to/old/files                "$NEW"/ 2>/dev/null || true
sudo cp    /path/to/old/licensekey.dat       "$NEW"/ 2>/dev/null || true

# Optional but recommended: copy the old SSH host key so the ServerQuery
# fingerprint stays the same and any host-key-pinning clients keep working.
sudo cp    /path/to/old/ssh_host_rsa_key     "$NEW"/

# The copies above are root-owned; hand them to the server's user (1000:1000),
# or adjust to your PUID/PGID.
sudo chown -R 1000:1000 "$NEW"

docker compose up -d
```

Your virtual server, channels, permissions, and admin identity carry over. If
you bring the old `ssh_host_rsa_key`, the SSH fingerprint is unchanged too;
otherwise the server generates a fresh one on first boot (which then stays
stable, since it lives on the volume).

> Note: `ssh-keyscan` does **not** work reliably against TeamSpeak's SSH
> ServerQuery — its older libssh stack closes the probe — so retrieve the key by
> copying the file rather than scraping it. Clients connect fine as long as they
> negotiate the `rsa-sha2-512` host-key algorithm TeamSpeak requires.

## Hardening

- Keep `TS3_QUERY_PROTOCOLS=ssh`; don't expose the plaintext raw query port
  (`10011`) — especially not over the public internet.
- Restrict the ServerQuery port (`10022`) with a host firewall to the sources
  that actually need it.
- Add those source IPs to `/data/query_ip_allowlist.txt` to exempt them from
  query flood protection (the container seeds it with `127.0.0.1` so the
  healthcheck is never flood-banned).

## Building

```sh
docker build -t ts3-server-arm64 .          # on arm64
# or cross-build from another arch:
docker buildx build --platform linux/arm64 -t ts3-server-arm64 .
```

Images are published to GHCR by [`.github/workflows/build.yml`](.github/workflows/build.yml)
on any `v*` tag, and also weekly (see below).

## Automation

Two scheduled workflows keep things current **without ever changing what's
running** — automation produces a reviewable PR or a republished image; you
decide when to deploy (`docker compose pull && up -d`).

- **[`update-teamspeak.yml`](.github/workflows/update-teamspeak.yml)** — weekly,
  checks `teamspeak.com/versions/server.json`. On a new release it bumps the
  `Dockerfile` version/checksum pins, builds the image in CI to prove the new
  tarball downloads and matches its SHA256, and opens a **pull request**. Review
  it, merge, then tag a release to publish.
- **[`build.yml`](.github/workflows/build.yml)** — besides `v*` tags, also runs
  weekly to rebuild with a **fresh Debian base** (security updates), keeping the
  TeamSpeak and box64 versions pinned. It republishes `:latest` and a dated tag
  in GHCR; your running container is untouched until you pull.

> One-time setup: for the PR workflow, enable *Settings → Actions → General →
> Workflow permissions → "Allow GitHub Actions to create and approve pull
> requests"*.

### Bumping the TeamSpeak version manually

The `update-teamspeak.yml` workflow does this for you, but to do it by hand:

1. Look up the new version + SHA256 at `https://teamspeak.com/versions/server.json`
   under `.linux.x86_64` (`.version` / `.checksum`).
2. Update the `TS_VERSION` / `TS_SHA256` defaults in the `Dockerfile`.
3. Rebuild. The server tarball is downloaded at build and the `sha256sum -c`
   step fails the build on any mismatch.

### Bumping box64

Change `BOX64_VERSION` in the `Dockerfile`. Pin it deliberately — box64 point
releases can regress emulation; don't blind-upgrade a working server.

## Notes on box64

`BOX64_DYNAREC_STRONGMEM=1` is set in the image. TeamSpeak is multithreaded x86
code that assumes strong (TSO) memory ordering; arm64 is weakly ordered, so this
flag is required to avoid rare, hard-to-reproduce data/DB corruption in a
long-running server. The image uses box64's generic arm64 dynarec for
portability; for a known CPU you can build with a target flag (see the comment
in the `Dockerfile`) for extra performance.

## License

The files in this repository (Dockerfile, entrypoint, workflows, compose,
docs) are licensed under the [MIT License](LICENSE).

This project only *packages* TeamSpeak; it contains no TeamSpeak code. The
TeamSpeak server itself is downloaded at build time and remains subject to the
[TeamSpeak license](https://www.teamspeak.com/en/privacy-and-terms/) — by
building or running the image you accept it (the container sets
`TS3SERVER_LICENSE=accept`). MIT covers this repo's packaging only, not the
bundled TeamSpeak binary.
