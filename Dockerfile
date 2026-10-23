# Rust dedicated server image for Flux.
#
# The game is NOT in the image. SteamCMD installs it (app 258550, about 6 GB) into the install
# volume on the first start and updates it on every start after; a watcher restarts the server,
# with a warning in game, as soon as Facepunch ships a build. So a Rust update never needs a new
# image, and a new image is never rolled out to servers that are already up to date. Carbon is
# fetched the same way for a modded server (FLUX_FRAMEWORK=carbon). See README.md.
#
# The base. CI builds it pinned to the digest it resolved and records that digest in the
# org.opencontainers.image.base.digest label, which the scheduled check compares against
# (.github/ci/needs-rebuild.sh).
ARG BASE_IMAGE=steamcmd/steamcmd:ubuntu-24
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# gettext-base: envsubst, for the ${VARS} in the spec's arguments. util-linux: flock.
RUN apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps tzdata python3 gettext-base util-linux libsqlite3-0 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-restart.sh scripts/flux-updatewatch.sh \
     scripts/flux-scheduler.sh scripts/flux-rcon.py scripts/flux-steam.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-rcon.py /usr/local/bin/flux-rcon && \
    ln -s /opt/flux/flux-restart.sh /usr/local/bin/flux-restart

# SteamCMD updates itself on its first run; done here so a server's first start does not.
RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

WORKDIR /srv/rust

# Game 28015/udp, RCON 28016/tcp, Steam query 28017/udp, Rust+ companion 28082/tcp.
EXPOSE 28015/udp 28016/tcp 28017/udp 28082/tcp

# A first start downloads the game and generates the map: up to half an hour on a large one.
HEALTHCHECK --interval=60s --timeout=10s --start-period=45m --retries=3 \
    CMD pgrep -x RustDedicated >/dev/null || exit 1

ENTRYPOINT ["/opt/flux/flux-entrypoint.sh"]
