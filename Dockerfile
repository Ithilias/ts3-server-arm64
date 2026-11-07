# syntax=docker/dockerfile:1
#
# TeamSpeak 3 server for arm64, running the 64-bit x86 binary under box64.
# box64 is built from a pinned, commit-verified source tag; the TeamSpeak server
# is downloaded at build time and SHA256-verified (never committed to this repo).
# No stage executes x86 code, so a plain `docker build` works on any arm64 host
# without amd64 emulation (binfmt/QEMU).

########################################################################
# Stage 1: build box64 from a pinned source tag
########################################################################
FROM arm64v8/debian:trixie-slim AS box64-builder

# Bump both together: the commit check fails the build if the tag was moved.
ARG BOX64_VERSION=v0.4.4
ARG BOX64_COMMIT=2f130fab1d6e1a4ee8a71dc60cfdfcc839ad192a

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates cmake make gcc g++ python3 \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${BOX64_VERSION}" \
      https://github.com/ptitSeb/box64.git /src/box64 \
 && actual="$(git -C /src/box64 rev-parse HEAD)" \
 && if [ "$actual" != "${BOX64_COMMIT}" ]; then \
      echo "box64 ${BOX64_VERSION} is ${actual}, expected ${BOX64_COMMIT}" >&2; exit 1; \
    fi
WORKDIR /src/box64/build
# ARM_DYNAREC=ON builds the generic arm64 dynarec. For a known CPU you can add
# a target flag (e.g. -DRPI5ARM64=1) for extra performance; generic is portable.
# RelWithDebInfo (unstripped) on purpose: readable backtraces if box64 crashes.
RUN cmake .. -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo \
 && make -j"$(nproc)"

########################################################################
# Stage 1b: x86_64 libs that box64 emulates (does not wrap)
# box64 wraps libc/libm/libpthread/libdl/librt to native arm64, but runs the
# real x86_64 libstdc++ (+ its libgcc_s dep), so we must ship those. Fetched as
# amd64 .debs and unpacked on arm64, so nothing x86 runs during the build.
########################################################################
FROM arm64v8/debian:trixie-slim AS x86libs

# apt-get download drops privileges to _apt, so give it a directory it can write.
RUN install -d -o _apt /tmp/debs && cd /tmp/debs \
 && dpkg --add-architecture amd64 \
 && apt-get update \
 && apt-get download libstdc++6:amd64 libgcc-s1:amd64 \
 && for deb in ./*.deb; do dpkg-deb -x "$deb" /tmp/root; done \
 && mkdir -p /out \
 && cp -a /tmp/root/usr/lib/x86_64-linux-gnu/libstdc++.so.6* /out/ \
 && cp -a "$(find /tmp/root -name libgcc_s.so.1)" /out/ \
 && rm -rf /var/lib/apt/lists/* /tmp/debs /tmp/root

########################################################################
# Stage 1c: download + verify the TeamSpeak server (kept out of the repo)
########################################################################
FROM arm64v8/debian:trixie-slim AS tsfetch

# Pin + verify the TeamSpeak release. Override at build time to bump versions;
# version + checksum are published at teamspeak.com/versions/server.json
# (.linux.x86_64). The sha256sum check fails the build on any mismatch.
ARG TS_VERSION=3.13.8
ARG TS_SHA256=a3c4658e09892d3dbd8ea752d0de42dc7d111bf44d09721927f0f4782496eb2d

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl bzip2 \
 && rm -rf /var/lib/apt/lists/*

# The tarball ships world-writable dirs/files (0777/0666, e.g. the SQL the
# server executes); extract without its owners/modes and drop group/other write.
RUN curl -fsSL -o /tmp/ts3.tar.bz2 \
      "https://files.teamspeak-services.com/releases/server/${TS_VERSION}/teamspeak3-server_linux_amd64-${TS_VERSION}.tar.bz2" \
 && echo "${TS_SHA256}  /tmp/ts3.tar.bz2" | sha256sum -c - \
 && mkdir -p /opt/ts3 \
 && tar xjf /tmp/ts3.tar.bz2 --strip-components=1 -C /opt/ts3 \
      --no-same-owner --no-same-permissions \
 && chmod -R go-w /opt/ts3 \
 && rm /tmp/ts3.tar.bz2 \
 && rm -rf /opt/ts3/doc /opt/ts3/redist /opt/ts3/tsdns \
           /opt/ts3/libts3db_mariadb.so /opt/ts3/libts3db_postgresql.so \
           /opt/ts3/sql/create_mariadb /opt/ts3/sql/create_postgresql \
           /opt/ts3/CHANGELOG /opt/ts3/ts3server_minimal_runscript.sh \
           /opt/ts3/ts3server_startscript.sh

########################################################################
# Stage 2: runtime
########################################################################
FROM arm64v8/debian:trixie-slim AS runtime

# `upgrade` so every (re)build ships current Debian security fixes, not only
# what was in the base image when it was last published.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get install -y --no-install-recommends \
      ca-certificates gosu netcat-openbsd tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY --from=box64-builder /src/box64/build/box64 /usr/local/bin/box64
COPY --from=tsfetch /opt/ts3 /opt/ts3

# x86_64 libstdc++ (+ libgcc_s) that box64 runs emulated, placed alongside the
# binary so box64 resolves them via BOX64_LD_LIBRARY_PATH below.
COPY --from=x86libs /out/ /opt/ts3/

RUN groupadd -g 1000 ts \
 && useradd -u 1000 -g 1000 -m -d /home/ts -s /usr/sbin/nologin ts \
 && mkdir -p /data && chown ts:ts /data

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# LANG=C.UTF-8 gives the server a UTF-8 locale (glibc built-in, no locales
# package needed); without it TS3 warns that the "C" locale may misbehave with
# non-ASCII names.
#
# STRONGMEM=4 + BIGBLOCK=0 harden box64's memory-model emulation: the x86 TS3
# binary is heavily threaded, and on arm64's weaker ordering box64's default weak
# barriers let threads race on glibc malloc/shm metadata. STRONGMEM=4 mimics x86
# TSO (like QEMU) and is the strongest setting; BIGBLOCK=0 is box64's recommended
# setting for heavily-threaded programs. Upstream labels level 4 "for evaluation
# purposes", so re-check crash behaviour whenever box64 is bumped.
#
# Why 4 and not 3: on this exact workload the previous QEMU-based image was
# effectively crash-free over years, while box64 with STRONGMEM=3 still produced
# a rare hard crash ("double free detected in tcache", a core dump) plus a benign
# but frequent accounting hiccup (see the accounting note in the README). The x86
# binary genuinely relies on TSO, so we match QEMU's ordering. Trade-off is some
# emulation speed, which a TS3 server (not CPU-bound) can absorb.
#
# LD_LIBRARY_PATH=/opt/ts3 is set only for the server process (entrypoint), not
# image-wide: that directory holds x86 libs native tools have no business seeing.
ENV TS3SERVER_LICENSE=accept \
    LANG=C.UTF-8 \
    BOX64_LD_LIBRARY_PATH=/opt/ts3 \
    BOX64_DYNAREC_STRONGMEM=4 \
    BOX64_DYNAREC_BIGBLOCK=0

WORKDIR /data
VOLUME /data

# 9987/udp voice · 30033/tcp file transfer · 10022/tcp SSH ServerQuery
EXPOSE 9987/udp 30033/tcp 10022/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD ["/entrypoint.sh", "healthcheck"]

ENTRYPOINT ["/entrypoint.sh"]
