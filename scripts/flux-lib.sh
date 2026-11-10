#!/bin/bash
# Shared helpers for the Rust image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. The install (SteamCMD's, a local `ml:` volume that is never synced) holds two other
# mounts inside it: the world (`server/<identity>`, the synced `g:` volume) and Carbon's tree
# (`carbon`, an `m:` volume with the customer's plugins and configs). The install is disposable:
# an empty one is filled from Steam on the next start.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/srv/rust}"
FLUX_CARBON_DIR="${FLUX_CARBON_DIR:-${FLUX_SERVER_DIR}/carbon}"
# Our own state on the install volume: the Carbon downloads, the last update attempt.
FLUX_STATE_DIR="${FLUX_STATE_DIR:-${FLUX_SERVER_DIR}/.flux}"
# flux.log is on the INSTALL volume (local, never synced): it is written on every line, and on the
# synced world volume that would be constant Syncthing traffic. One rotated copy (flux.log.1).
FLUX_LOG_DIR="${FLUX_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_LOG="${FLUX_LOG-${FLUX_LOG_DIR}/flux.log}"
FLUX_LOG_MAX_BYTES="${FLUX_LOG_MAX_BYTES:-5242880}"

FLUX_STEAM_APP="${FLUX_STEAM_APP:-258550}"
FLUX_GAME_BINARY="${FLUX_GAME_BINARY:-RustDedicated}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-RustDedicated}"

# Where the running generation leaves what the helpers (flux-rcon, the watchers) need.
FLUX_RUN_DIR="${FLUX_RUN_DIR:-/tmp/flux}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-${FLUX_RUN_DIR}/restart-requested}"
FLUX_RCON_ENV="${FLUX_RCON_ENV:-${FLUX_RUN_DIR}/rcon.env}"
# The Carbon version the running server was started with ("none" for a vanilla start, or for a
# Carbon server that had to start without it).
FLUX_CARBON_ACTIVE="${FLUX_CARBON_ACTIVE:-${FLUX_RUN_DIR}/carbon-active}"
# When the running server started (epoch seconds); the update watcher leaves a booting one alone.
FLUX_STARTED_AT="${FLUX_STARTED_AT:-${FLUX_RUN_DIR}/started-at}"

# Carbon: the channel followed, and where its two release files are published. Carbon republishes
# `production_build` in place, so the version is read from the .info file next to the archive.
FLUX_CARBON_TAG="${FLUX_CARBON_TAG:-production_build}"
FLUX_CARBON_URL="${FLUX_CARBON_URL:-https://github.com/CarbonCommunity/Carbon/releases/download}"
# The customer's part of the Carbon tree: never replaced. Everything else is the runtime and is
# refreshed from the release on every start.
FLUX_CARBON_USER_DIRS="${FLUX_CARBON_USER_DIRS:-plugins configs data lang extensions}"
FLUX_CARBON_RUNTIME_DIRS="${FLUX_CARBON_RUNTIME_DIRS:-managed tools native}"
# The file whose presence means "this tree holds a usable Carbon runtime".
FLUX_CARBON_MARKER="${FLUX_CARBON_MARKER:-tools/environment.sh}"

# One line, to the container's output and (when FLUX_LOG is set) to flux.log, rotated at
# FLUX_LOG_MAX_BYTES (the old file becomes flux.log.1).
flux_log_raw() {
  printf '%s\n' "$1"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "$1" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_rotate_log "${FLUX_LOG}" "${FLUX_LOG_MAX_BYTES}"
  fi
  return 0
}

flux_log() {
  flux_log_raw "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
}

# Moves $1 to $1.1 (replacing the previous one) once it is larger than $2 bytes.
flux_rotate_log() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  if [ "${size}" -gt "$2" ] 2>/dev/null; then
    mv -f "$1" "$1.1" 2>/dev/null
  fi
  return 0
}

# The start-up banner, through the normal log path (docker logs, the panel's log). ASCII only.
flux_banner() {
  local rule='====================================================================='
  flux_log_raw "${rule}"
  flux_log_raw " Rust server image by FluxCloud - https://runonflux.com"
  flux_log_raw " Host this and 30+ other games in one click: https://runonflux.com/games"
  flux_log_raw "${rule}"
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = FLUX_FRAMEWORK. Prints `carbon` or `vanilla`; returns 1 for anything else. Empty is
# vanilla: the official game, which is what a spec that says nothing about mods should get.
flux_framework() {
  case "${1,,}" in
    '' | vanilla | none | off) printf 'vanilla' ;;
    carbon) printf 'carbon' ;;
    *) return 1 ;;
  esac
}

# $1 = STEAM_BRANCH. Prints it, or returns 1 for a name SteamCMD should never be handed.
# Empty is public.
flux_steam_branch() {
  local value="${1:-public}"
  [[ "${value}" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 1
  printf '%s' "${value}"
}

# $1 = an appmanifest_<app>.acf. Prints the installed build id, or nothing.
flux_acf_buildid() {
  sed -n 's/^[[:space:]]*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

# $1 = the installed build, $2 = the newest build Steam lists. True when $2 is a real build id
# that is not the one installed. Not "greater than": Steam can roll a branch BACK, and a server
# on the pulled build would then refuse the players on the restored one.
flux_build_is_new() {
  [[ "$2" =~ ^[0-9]+$ ]] || return 1
  [ "$1" != "$2" ]
}

# $1 = the name of a convar (rcon.port), then the server's arguments. Prints the value that
# follows the last `+<name>` (the game reads them in order, so a later one wins).
flux_arg_value() {
  local name="+$1" found="" prev=""
  shift
  local arg
  for arg in "$@"; do
    [ "${prev}" = "${name}" ] && found="${arg}"
    prev="${arg}"
  done
  printf '%s' "${found}"
}

# $1 = a port value. Prints it, or returns 1 for a value that is not a usable port.
flux_valid_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1 ] && [ "${value}" -le 65535 ] || return 1
  printf '%s' "${value}"
}

# $1 = SERVER_PORT, then the server's arguments. Prints the port the game must be given with
# `+server.port` when the arguments do not carry one and $1 is a usable port, else nothing.
# A spec that is already at the 20 commands FluxOS allows (the Modded app) cannot spend two more
# on the game port, which the hub moves off 28015 so several servers can share a node address.
flux_server_port_fallback() {
  local fallback="${1:-}"
  shift
  [ -z "$(flux_arg_value server.port "$@")" ] || return 0
  flux_valid_port "${fallback}" || true
}

# ---------------------------------------------------------------------------------------------
# A map of its own, sized for the plan, on a server's first boot.
# ---------------------------------------------------------------------------------------------

# The container's memory limit in MB, or nothing when there is none (cgroup v2, then v1).
flux_memory_limit_mb() {
  local raw=""
  if [ -r /sys/fs/cgroup/memory.max ]; then raw="$(cat /sys/fs/cgroup/memory.max)"
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then raw="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"; fi
  [[ "${raw}" =~ ^[0-9]+$ ]] || return 0
  # An unlimited container reports a number near 2^63.
  [ "${#raw}" -le 13 ] || return 0
  printf '%s' $((raw / 1048576))
}

# $1 = memory in MB. Prints the map size that memory carries comfortably: the engine's own 4500
# generates for ~28 minutes and holds 94% of an 8 GB plan (measured), so the smaller plans get
# less. Nothing for an unknown or empty memory.
flux_world_size_for_mb() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ] || return 0
  if [ "$1" -le 9500 ]; then printf '3000'
  elif [ "$1" -le 13500 ]; then printf '3500'
  else printf '4500'; fi
}

# $1 = the server's identity directory, $2 = memory in MB (may be empty), $3 = a seed, then the
# server's arguments. Prints the server.cfg lines a NEW server should start with: a map size for
# its plan and a seed of its own, instead of the engine's 4500 and 1337 that every server without
# them shares. Prints nothing for a server that has ever had a world (a save, a wipe folder, the
# marker below), for a convar the arguments already set, for one server.cfg already sets, and for a
# server on a custom map. The server.cfg is read when the arguments carry nothing, which is how
# the dashboard's Server Settings and its wipe keep working on these two settings.
flux_map_cfg_lines() {
  local dir="$1" mem="$2" seed="$3" cfg size
  shift 3
  cfg="${dir}/cfg/server.cfg"
  [ -f "${dir}/.flux-map-init" ] && return 0
  compgen -G "${dir}/proceduralmap.*" >/dev/null && return 0
  [ -d "${dir}/flux-wipes" ] && return 0
  if [ -f "${cfg}" ] && grep -qE '^[[:space:]]*server\.(level|levelurl)[[:space:]]' "${cfg}"; then return 0; fi
  size="$(flux_world_size_for_mb "${mem}")"
  if [ -n "${size}" ] && [ -z "$(flux_arg_value server.worldsize "$@")" ] \
    && ! { [ -f "${cfg}" ] && grep -qE '^[[:space:]]*server\.worldsize[[:space:]]' "${cfg}"; }; then
    printf 'server.worldsize "%s"\n' "${size}"
  fi
  if [[ "${seed}" =~ ^[0-9]{1,10}$ ]] && [ -z "$(flux_arg_value server.seed "$@")" ] \
    && ! { [ -f "${cfg}" ] && grep -qE '^[[:space:]]*server\.seed[[:space:]]' "${cfg}"; }; then
    printf 'server.seed "%s"\n' "${seed}"
  fi
}

# The spec passes `${RCON_PASSWORD}` and friends inside the server arguments, and the image they
# were written for expanded them. Sets FLUX_EXPANDED_ARGS.
flux_expand_args() {
  local arg
  FLUX_EXPANDED_ARGS=()
  for arg in "$@"; do
    FLUX_EXPANDED_ARGS+=("$(printf '%s' "${arg}" | envsubst)")
  done
}

# ---------------------------------------------------------------------------------------------
# Scheduled restarts.
# ---------------------------------------------------------------------------------------------

# $1 = FLUX_RESTART_TIME ("HH:MM"). Prints the minute of the day, or returns 1.
flux_restart_minute_of_day() {
  local value="$1" h m
  [[ "${value}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  [ "${h}" -le 23 ] && [ "${m}" -le 59 ] || return 1
  printf '%s' $((h * 60 + m))
}

# $1 = minute of the day the restart is set for, $2 = the current minute of the day, $3 = the
# current second of that minute. Prints how many seconds until the next restart. A restart due
# this very minute is tomorrow's: otherwise a server that restarts at 05:00 and is back up at
# 05:00:40 restarts again.
flux_seconds_until() {
  local target="$1" now_min="$2" now_sec="${3:-0}" delta
  delta=$(((target - now_min) * 60 - now_sec))
  [ "${delta}" -le 0 ] && delta=$((delta + 86400))
  printf '%s' "${delta}"
}

# $1 = a warning in minutes. Prints it clamped to 0..30 (5 for anything unreadable).
flux_warn_minutes() {
  local value="${1:-5}"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=5
  value=$((10#${value}))
  [ "${value}" -gt 30 ] && value=30
  printf '%s' "${value}"
}

# $1 = a check interval in minutes. Prints it clamped to 2..1440 (10 for anything unreadable).
flux_check_minutes() {
  local value="${1:-10}"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=10
  value=$((10#${value}))
  [ "${value}" -lt 2 ] && value=2
  [ "${value}" -gt 1440 ] && value=1440
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. One that was asked for (an update, the daily restart, an
# admin's `quit`) is the plan working, not a crash.
flux_restart_counts() {
  case "$1" in
    planned* | requested* | scheduled* | update*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Carbon.
# ---------------------------------------------------------------------------------------------

# $1 = the tree. True when it has no usable runtime and must be seeded whole.
flux_carbon_needs_seed() {
  [ ! -f "$1/${FLUX_CARBON_MARKER}" ]
}

# $1 = a release (its carbon/ folder), $2 = the server's tree. Seeds an empty tree whole; on a
# tree that has one, replaces only the runtime. Plugins, configs, data, lang and extensions are
# the customer's and are never touched: overwriting them would undo a configuration change
# between one restart and the next.
flux_carbon_install() {
  local release="$1" dir="$2" sub
  mkdir -p "${dir}" || return 1
  if flux_carbon_needs_seed "${dir}"; then
    cp -a "${release}/." "${dir}/" || return 1
  else
    for sub in ${FLUX_CARBON_RUNTIME_DIRS}; do
      [ -d "${release}/${sub}" ] || continue
      rm -rf "${dir:?}/${sub}" && cp -a "${release}/${sub}" "${dir}/" || return 1
    done
  fi
  for sub in ${FLUX_CARBON_USER_DIRS}; do mkdir -p "${dir}/${sub}"; done
  return 0
}

# $1 = the cache directory (one folder per version). Prints the newest cached version that is
# complete, or nothing.
flux_carbon_cached() {
  local d
  # shellcheck disable=SC2012  # our own folder names, newest first
  while IFS= read -r d; do
    if [ -f "$1/${d}/carbon/${FLUX_CARBON_MARKER}" ] && [ -f "$1/${d}/libdoorstop.so" ]; then
      printf '%s' "${d}"
      return 0
    fi
  done < <(ls -1t "$1" 2>/dev/null)
  return 0
}

# $1 = the cache directory, $2 = the version in use. Deletes every other folder but the newest
# complete one (half-finished downloads included): each release is about 50 MB on a disk the
# customer pays for.
flux_carbon_prune() {
  local newest d
  newest="$(flux_carbon_cached "$1")"
  for d in "$1"/* "$1"/.download-*; do
    [ -e "${d}" ] || continue
    d="${d##*/}"
    [ "${d}" = "${newest}" ] || [ "${d}" = "$2" ] && continue
    rm -rf "${1:?}/${d}"
  done
}

# $1 = Carbon's config.json. Turns Carbon's own self-updater off, creating the file when it is not
# there yet (Carbon fills in the rest on its first start), and prints what it did, or nothing.
#
# The self-updater runs `curl` with Process.Start in Carbon.Preloader, before Carbon has even
# logged a line. On Flux nodes the child Mono forks for that never reaches exec: it spins at 100%
# CPU and the server hangs at boot forever, with nothing in its log after "Mono config path"
# (seen 2026-10-23 on the first Carbon server moved to this image; the older image had no curl,
# so the start failed at once and nothing forked). We update Carbon ourselves (carbon_release and
# the update watch), so nothing is lost. A file that is not JSON is set aside: Carbon would replace
# it with its defaults, self-updater on.
flux_carbon_disable_selfupdate() {
  python3 - "$1" <<'EOF'
import json, os, sys, time
path = sys.argv[1]
try:
    with open(path, encoding="utf-8-sig") as f:
        config = json.load(f)
    if not isinstance(config, dict):
        raise ValueError("not an object")
except FileNotFoundError:
    config, note = {}, "created %s with the self-updater off" % os.path.basename(path)
except (ValueError, UnicodeDecodeError):
    aside = "%s.broken.%d" % (path, int(time.time()))
    os.replace(path, aside)
    config, note = {}, "%s was not valid JSON (kept as %s); wrote one with the self-updater off" % (
        os.path.basename(path), os.path.basename(aside))
else:
    note = "turned Carbon's self-updater off"
updating = config.get("SelfUpdating")
if not isinstance(updating, dict):
    updating = config["SelfUpdating"] = {}
if updating.get("Enabled") is False:
    sys.exit(0)
updating["Enabled"] = False
tmp = path + ".flux-tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
os.replace(tmp, path)
print(note)
EOF
}

# Kills every game process still alive between two generations, and prints how many it found. A
# child the game forked outlives a kill of the game itself: it is reparented to us and keeps a core
# busy beside the next generation (seen 2026-10-23, the self-updater fork above, for hours).
flux_kill_leftover_games() {
  local pids
  pids="$(pgrep -x "${FLUX_GAME_PROCESS}" 2>/dev/null)"
  [ -n "${pids}" ] || return 0
  # shellcheck disable=SC2086  # one pid per word
  kill -KILL ${pids} 2>/dev/null
  wc -w <<<"${pids}"
}

# $1 = a Carbon version string. True when it is safe as a folder name.
flux_carbon_version_ok() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$ ]]
}

# ---------------------------------------------------------------------------------------------
# The world on disk.
# ---------------------------------------------------------------------------------------------

# $1 = a server identity folder. Repairs a save that was cut off while it was being written, and
# prints one line per file it changed.
#
# RustDedicated writes `<world>.sav.new` and then puts it in place as `<world>.sav`; a `.sav.new`
# left on disk means that save never finished (none is left after a normal save, checked on a
# real server). Which copy is whole depends on where it was cut:
#
#   .sav newer than .sav.new   cut while replacing .sav: .sav is the truncated one, .sav.new whole
#   .sav older (or missing)    cut while writing .sav.new: .sav is the previous save, whole
#
# Left alone, a truncated .sav fails to load ("Error loading save ... EndOfStreamException") and
# the server can hang right after with the CPU pegged and nothing more in its log (seen
# 2026-10-23 on a server cut mid-save six days earlier). The copy set aside is renamed
# `broken-<name>.<epoch>`, which the game never loads and the dashboard's next wipe clears.
flux_recover_interrupted_saves() {
  local dir="$1" new sav stamp
  stamp="$(date -u +%s)"
  for new in "${dir}"/*.sav.new; do
    [ -f "${new}" ] || continue
    sav="${new%.new}"
    if [ ! -e "${sav}" ] || [ "${sav}" -nt "${new}" ]; then
      [ -e "${sav}" ] && mv -f "${sav}" "${dir}/broken-${sav##*/}.${stamp}"
      mv -f "${new}" "${sav}"
      printf 'restored %s from %s\n' "${sav##*/}" "${new##*/}"
    else
      mv -f "${new}" "${dir}/broken-${sav##*/}.${stamp}"
      printf 'kept %s; set aside an unfinished %s\n' "${sav##*/}" "${new##*/}"
    fi
  done
}

# ---------------------------------------------------------------------------------------------
# The running server.
# ---------------------------------------------------------------------------------------------

flux_game_pid() {
  pgrep -x "${FLUX_GAME_PROCESS}" 2>/dev/null | head -1
}

# $1 = the epoch the server started, $2 = now, $3 = the grace in seconds. True while it is still
# inside its boot grace (a map that is generating cannot be told anything).
flux_booting() {
  [ -n "$1" ] || return 0
  [ $(($2 - $1)) -lt "$3" ]
}
