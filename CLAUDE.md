# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**, not an application: the Rust dedicated server for Flux,
`runonflux/rust-server-flux`, Vanilla and Carbon in one image. steamcmd/steamcmd:ubuntu-24 and a
supervisor in bash. Same family as `~/work/garrysmod-server-flux` and `~/work/7dtd-server-flux`;
read them for the patterns this one follows. It replaces `~/work/rust-carbon-server` (game baked
into the image), which existing servers still run until they take the hub's update.

The rule that shapes everything: **the game is not in the image.** SteamCMD installs and updates
it on every start, and the update watch restarts the server onto a new build. A new image is a
redeploy of every server on the network (FluxOS's image update service), so it is for changes to
the scripts only.

## Commands

```bash
./tests/test-flux.sh
docker build -t rust-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image; CI gates the publish on it
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A change to what the image does bumps `VERSION` and gets a line under "Versions" in the README.

## The files

- `scripts/flux-entrypoint.sh`: PID 1. Per generation: SteamCMD update (with the 0x6 fallback),
  Carbon, `RustDedicated` as a child with its environment set explicitly (the supervisor itself is
  never preloaded). Starts the two watchers once.
- `scripts/flux-updatewatch.sh`: asks Steam (flux-steam.py) and GitHub (Carbon) and calls
  flux-restart.sh when something moved.
- `scripts/flux-scheduler.sh`: the daily restart at FLUX_RESTART_TIME.
- `scripts/flux-restart.sh`: warn over RCON, save, leave the reason in the marker, SIGTERM. One at
  a time (flock).
- `scripts/flux-rcon.py`: a stdlib WebRCON client. `scripts/flux-steam.py`: app_info_print -> build id.
- `scripts/flux-lib.sh`: shared helpers. **Sourcing it must stay side-effect free**: the tests
  source it directly.

## Things that will bite you

- **depotcache**: an update needs the INSTALLED build's manifests, and Steam refuses old ones to an
  anonymous login (state 0x6). Kept on the install volume via a symlink; the fallback is a full
  reinstall over the top (only when the output says 0x6, never on a network failure).
- **SteamCMD's app info is cached**: flux-steam.py deletes appinfo.vdf before asking.
- **`carbon/tools/environment.sh` is not sourced**: it would preload doorstop into PID 1 and every
  tool it runs. Its four variables are passed to the game alone.
- **The marker decides crash vs plan**: a reason starting with planned/requested/scheduled/update
  does not count against the restart budget.
- **Mount order**: the install volume is the parent of the world and the Carbon mounts. Docker
  mounts by depth, so this works, and GMod's spec has run the same nesting since 2026-10.
- **The unit tests run with the machine's Python, not the image's.** Anything a script newly needs
  gets a check in `tests/image/in-container.sh`.
