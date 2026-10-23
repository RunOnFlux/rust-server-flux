# rust-server-flux

The Rust dedicated server image for Flux: `runonflux/rust-server-flux`. One image for Vanilla and
Modded (Carbon). Written from scratch on `steamcmd/steamcmd:ubuntu-24`, in the same family as
`runonflux/garrysmod-server-flux` and `runonflux/7dtd-server-flux`.

## Why the game is not in the image

The images it replaces (`pfeiffermax/rust-game-server`, and `runonflux/rust-carbon-server` built
on it) carry the game inside. A Facepunch update then means a new image, and FluxOS rolls a new
`:latest` out to every server as a soft redeploy, hours later and whether or not that server
needed it. Until it arrives, players are refused with "Wrong Connection Protocol: Server update
required!", and restarting the server does nothing.

Here SteamCMD installs the game (app 258550) into the install volume on the first start and
updates it on every start, and `flux-updatewatch.sh` restarts the server, with a warning in game,
as soon as Steam lists a new build. This image changes only when its own scripts do.

## What it does

- **Every start**: SteamCMD update, then Carbon for a modded server, then `RustDedicated` as a
  child of the supervisor (PID 1). A crash is restarted in place; five within an hour end the
  container with 42 so the platform can move it.
- **Update watch** (`FLUX_AUTO_UPDATE`, on by default): Steam is asked every 10 minutes. A new
  build means a 5 minute warning in chat, then a save and a restart onto it. A Carbon server
  restarts for a new Carbon release too, and for Carbon itself if it could not be fetched at the
  last start. An update that did not take is not retried for an hour.
- **Daily restart** (`FLUX_RESTART_TIME`, off by default): the same warning, save and restart.
- **Carbon** (`FLUX_FRAMEWORK=carbon`): the `production_build` release, fetched from GitHub on
  every start when it moved, cached on the install volume (the last one is used when GitHub is
  unreachable). The runtime (`managed`, `tools`, `native`) is refreshed; `plugins`, `configs`,
  `data`, `lang` and `extensions` are the owner's and never touched. The game runs as root, so a
  plugin FluxOS writes as root loads at once (the old image needed an inotify chown for that).
- **A save cut off mid-write** (a `.sav.new` left on disk) is repaired before every start: the
  whole copy becomes the `.sav`, the other is kept as `broken-<name>.<epoch>`. A truncated `.sav`
  otherwise fails to load and can leave the server hung at boot with the CPU pegged.
- **`docker stop`**: `server.save` over RCON, then SIGTERM. RustDedicated does not save on SIGTERM
  (it exits in about two seconds and the world is the last autosave), which is what the images this
  one replaces did on every stop.
- `flux-rcon "<command>"` and `flux-restart "<reason>" [warn minutes]` inside the container.

## App spec

```
containerData: g:/srv/rust/server/<identity>|ml:game:/srv/rust|m:carbon:/srv/rust/carbon
```

- `g:` the world (`server/<identity>`), synced to the second instance. Same path as every older
  Rust spec, so a server keeps its world when it moves onto this image.
- `ml:game` the install. Local: never synced (FluxOS 8.19+ keeps `ml:` out of Syncthing) and never
  in a backup. A node that takes the server over installs the game itself.
- `m:carbon` the Carbon tree with the owner's plugins. On a Vanilla server it is simply unused.

Docker mounts the parent first, so the two folders inside `/srv/rust` show through the install.

The arguments are the old images' (`+rcon.port 28016 +rcon.password ${RCON_PASSWORD}
+server.identity ...`), with `${VARS}` expanded as they were.

| Variable | Default | |
|---|---|---|
| `FLUX_FRAMEWORK` | (vanilla) | `carbon` for a modded server |
| `FLUX_AUTO_UPDATE` | on | `false` to wait for a restart instead |
| `FLUX_UPDATE_CHECK_MINUTES` | 10 | 2..1440 |
| `FLUX_UPDATE_WARN_MINUTES` | 5 | 0..30 |
| `FLUX_RESTART_TIME` / `TZ` | (off) / UTC | `HH:MM` daily restart |
| `FLUX_RESTART_WARN_MINUTES` | 5 | 0..30 |
| `STEAM_BRANCH` | public | a Steam beta branch |
| `SKIP_UPDATE` | off | do not run SteamCMD when the game is installed |

## Measured (2026-10-23, build 26139947)

- First install: 6.1 GB, 69 s on a fast line. An update with nothing to do: 11 s.
- Carbon 2.0.262: a 21 MB download, 2 s.
- Moving a server off `runonflux/rust-carbon-server` (same world and Carbon volumes, an empty
  install volume): game installed in 73 s, up in 110 s, the 381 saved entities loaded, the uMod
  plugin already in the folder loaded. Files the old image left owned by 10001 are no obstacle.
- `docker stop`: world saved over RCON, exit 0, 4.4 s in all.
- A new build seen by the update watch: warned, saved, restarted, world loaded from the save.
- **SteamCMD's depotcache must survive a redeploy.** An update from build A needs A's manifests,
  and Steam refuses an old manifest to an anonymous login ("Failed to get manifest request code,
  'Access Denied'", state 0x6), even with `validate`. The image keeps `depotcache` on the install
  volume; when it is gone anyway, the update is redone as a fresh install over the top: the whole
  6 GB again and about 10 GB on the disk at the peak, which still fits the smallest plan (15 GB).

## Build and test

```bash
./tests/test-flux.sh                     # pure logic
docker build -t rust-server-flux:local .
./tests/test-image.sh                    # the supervisor around a stand-in Steam and game
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

## Versions

- **1.0.0** (2026-10-23): first release.
- **1.0.1** (2026-10-23): repairs a save that was cut off while being written, before each start.
- **1.0.2** (2026-10-23): Carbon servers hung at boot forever: Carbon's self-updater forks `curl`, and on Flux nodes that fork never reaches exec. It is now turned off in `carbon/config.json` before every start (the image keeps Carbon updated itself), and game processes left behind by a server that ended are killed before the next one starts.
