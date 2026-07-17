# syntax=docker/dockerfile:1
#
# TeamSpeak 3 server for arm64, running the 64-bit x86 binary under box64.
# box64 is built from a pinned source tag; the TeamSpeak server is downloaded at
# build time and SHA256-verified (never committed to this repo).

# The x86_64 lib stage below must be amd64 regardless of build host. Declared
# global (before the first FROM) so it's usable in that stage's FROM, and as an
# ARG (not a constant) to satisfy the Dockerfile linter.
ARG X86LIBS_PLATFORM=linux/amd64

########################################################################
# Stage 1 — build box64 from a pinned source tag
########################################################################
FROM arm64v8/debian:trixie-slim AS box64-builder

ARG BOX64_VERSION=v0.4.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates cmake make gcc g++ python3 \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${BOX64_VERSION}" \
      https://github.com/ptitSeb/box64.git /src/box64
WORKDIR /src/box64/build
# ARM_DYNAREC=ON builds the generic arm64 dynarec. For a known CPU you can add
# a target flag (e.g. -DRPI5ARM64=1) for extra performance; generic is portable.
RUN cmake .. -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo \
 && make -j"$(nproc)"

########################################################################
# Stage 1b — x86_64 libs that box64 emulates (does not wrap)
# box64 wraps libc/libm/libpthread/libdl/librt to native arm64, but runs the
# real x86_64 libstdc++ (+ its libgcc_s dep), so we must ship those.
########################################################################
FROM --platform=${X86LIBS_PLATFORM} debian:trixie-slim AS x86libs

RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 \
 && rm -rf /var/lib/apt/lists/*

########################################################################
# Stage 1c — download + verify the TeamSpeak server (kept out of the repo)
########################################################################
FROM debian:trixie-slim AS tsfetch

# Pin + verify the TeamSpeak release. Override at build time to bump versions;
# version + checksum are published at teamspeak.com/versions/server.json
# (.linux.x86_64). The sha256sum check fails the build on any mismatch.
ARG TS_VERSION=3.13.8
ARG TS_SHA256=a3c4658e09892d3dbd8ea752d0de42dc7d111bf44d09721927f0f4782496eb2d

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl bzip2 \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/ts3.tar.bz2 \
      "https://files.teamspeak-services.com/releases/server/${TS_VERSION}/teamspeak3-server_linux_amd64-${TS_VERSION}.tar.bz2" \
 && echo "${TS_SHA256}  /tmp/ts3.tar.bz2" | sha256sum -c - \
 && mkdir -p /opt/ts3 \
 && tar xjf /tmp/ts3.tar.bz2 --strip-components=1 -C /opt/ts3 \
 && rm /tmp/ts3.tar.bz2 \
 && rm -rf /opt/ts3/doc /opt/ts3/redist /opt/ts3/tsdns \
           /opt/ts3/libts3db_mariadb.so /opt/ts3/libts3db_postgresql.so \
           /opt/ts3/CHANGELOG /opt/ts3/ts3server_minimal_runscript.sh \
           /opt/ts3/ts3server_startscript.sh

########################################################################
# Stage 2 — runtime
########################################################################
FROM arm64v8/debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates gosu netcat-openbsd tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY --from=box64-builder /src/box64/build/box64 /usr/local/bin/box64
COPY --from=tsfetch /opt/ts3 /opt/ts3

# x86_64 libstdc++ (+ libgcc_s) that box64 runs emulated, placed alongside the
# binary so box64 resolves them via BOX64_LD_LIBRARY_PATH below.
COPY --from=x86libs /usr/lib/x86_64-linux-gnu/libstdc++.so.6* /opt/ts3/
COPY --from=x86libs /lib/x86_64-linux-gnu/libgcc_s.so.1 /opt/ts3/

RUN groupadd -g 1000 ts \
 && useradd -u 1000 -g 1000 -d /data -s /usr/sbin/nologin ts \
 && mkdir -p /data && chown ts:ts /data

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# LANG=C.UTF-8 gives the server a UTF-8 locale (glibc built-in, no locales
# package needed); without it TS3 warns that the "C" locale may misbehave with
# non-ASCII names.
ENV TS3SERVER_LICENSE=accept \
    LANG=C.UTF-8 \
    LD_LIBRARY_PATH=/opt/ts3 \
    BOX64_LD_LIBRARY_PATH=/opt/ts3 \
    BOX64_DYNAREC_STRONGMEM=1

WORKDIR /data
VOLUME /data

# 9987/udp voice · 30033/tcp file transfer · 10022/tcp SSH ServerQuery
EXPOSE 9987/udp 30033/tcp 10022/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD ["/entrypoint.sh", "healthcheck"]

ENTRYPOINT ["/entrypoint.sh"]
