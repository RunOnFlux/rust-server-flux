#!/bin/bash
# PID 1, and the supervisor of the Rust server.
#
# The game is NOT in the image. SteamCMD installs it into the install volume on the first start
# and updates it on every start after, so a new Facepunch build reaches a server by restarting
# it, never by rebuilding this image (which FluxOS would roll out as a redeploy of every server,
# up to date or not). Carbon, for a modded server, is fetched the same way.
#
# The game runs as a CHILD, never exec, so a stop reaches us first, and a server that ends on its
# own is followed by the next one in place:
#
#   - every start: SteamCMD update, Carbon (FLUX_FRAMEWORK=carbon), then RustDedicated
#   - SIGTERM/SIGINT from Docker: the world saved over RCON, then the game told to quit
#   - a planned restart (flux-updatewatch.sh on a new build, flux-scheduler.sh at
#     FLUX_RESTART_TIME): players warned over RCON, the world saved, a new generation, updated
#   - the server ending on its own: a new generation in the same container, updated first
#   - FLUX_RESTART_MAX_ATTEMPTS unplanned restarts inside FLUX_RESTART_WINDOW seconds: the
#     container ends with 42, a server that cannot stay up is the platform's to rebuild or move
#
# Same family as runonflux/garrysmod-server-flux and runonflux/7dtd-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a planned restart waits for the game to save and quit before it is killed. A docker
# stop is not bound by this: Docker kills on its own clock.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-120}"

s="${FLUX_SERVER_DIR}"

mkdir -p "${s}" "${FLUX_STATE_DIR}" "${FLUX_LOG_DIR}" "${FLUX_RUN_DIR}"
rm -f "${FLUX_RESTART_MARKER}" "${FLUX_STARTED_AT}"
flux_banner

# SteamCMD's depotcache onto the install volume. It holds the manifests of the installed build,
# which the NEXT update needs and which Steam refuses to an anonymous login once a build is old.
# In the container's own layer they would be lost on every redeploy, and the update after it
# would have to download the whole game again (see update_server).
steam_home="${HOME:-/root}/.local/share/Steam"
mkdir -p "${FLUX_STATE_DIR}/depotcache" "${steam_home}"
if [ ! -L "${steam_home}/depotcache" ]; then
  rm -rf "${steam_home}/depotcache"
  ln -s "${FLUX_STATE_DIR}/depotcache" "${steam_home}/depotcache"
fi

if ! framework="$(flux_framework "${FLUX_FRAMEWORK:-}")"; then
  flux_log "ERROR FLUX_FRAMEWORK='${FLUX_FRAMEWORK:-}' is not carbon or vanilla; refusing to start"
  exit 42
fi
if ! branch="$(flux_steam_branch "${STEAM_BRANCH:-}")"; then
  flux_log "ERROR STEAM_BRANCH='${STEAM_BRANCH:-}' is not a branch name; refusing to start"
  exit 42
fi
export FLUX_BRANCH="${branch}"
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, ${framework}, Steam branch ${branch})"

# The spec's arguments, ${VARS} expanded, as the image they were written for did.
flux_expand_args "$@"
set -- "${FLUX_EXPANDED_ARGS[@]+"${FLUX_EXPANDED_ARGS[@]}"}"
GAME_ARGS=("$@")

# RCON for our own helpers: the port and password the server is started with.
rcon_port="$(flux_valid_port "$(flux_arg_value rcon.port "$@")")" || rcon_port=28016
rcon_password="$(flux_arg_value rcon.password "$@")"
{
  printf 'RCON_PORT=%s\n' "${rcon_port}"
  printf 'RCON_PASSWORD=%s\n' "${rcon_password}"
} >"${FLUX_RCON_ENV}"
chmod 600 "${FLUX_RCON_ENV}"
[ -n "${rcon_password}" ] || flux_log "WARN no +rcon.password: players cannot be warned before a planned restart"

game_pid=""
terminating=0
generation=0
restart_history=()

# RustDedicated does NOT save on SIGTERM: it runs its shutdown handler and exits 0 in about two
# seconds, and the world on disk is the last autosave (measured: the image this one replaces left
# no .sav at all after a stop). So the world is saved over RCON first, inside Docker's 10 seconds,
# and only then is the game told to quit.
# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested ($1): saving the world, then quitting; no restart will follow"
  [ -n "${game_pid}" ] || return 0
  if [ -f "${FLUX_STARTED_AT}" ] && FLUX_RCON_TIMEOUT=5 flux-rcon --quiet server.save >/dev/null 2>&1; then
    # The save's last write and rename finish just after the command answers.
    sleep 1
    flux_log "world saved"
  else
    flux_log "WARN could not save over RCON; the world on disk is the last autosave"
  fi
  kill -TERM "${game_pid}" 2>/dev/null
}
trap 'term_handler TERM' TERM
trap 'term_handler INT' INT

disk_note() {
  local line
  line="$(df -Pm "${s}" 2>/dev/null | awk 'NR==2 {printf "%s MB free of %s MB", $4, $2}')"
  [ -n "${line}" ] && flux_log "install volume: ${line}"
}

update_server() {
  local attempt installed before beta=()
  installed=0
  [ -x "${s}/${FLUX_GAME_BINARY}" ] && installed=1
  if flux_truthy "${SKIP_UPDATE:-}" && [ "${installed}" = "1" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  [ "${FLUX_BRANCH}" != "public" ] && beta=(-beta "${FLUX_BRANCH}")
  before="$(flux_acf_buildid "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
  if [ "${installed}" = "1" ]; then
    flux_log "updating the server from Steam (app ${FLUX_STEAM_APP}, installed build ${before:-unknown})"
  else
    flux_log "installing the server from Steam (app ${FLUX_STEAM_APP}, about 6 GB the first time)"
  fi
  disk_note
  # 1: a plain update. No `validate`: it re-hashes the whole install.
  # 2: with validate, for an install that is damaged.
  # 3: only when Steam answered "state is 0x6": over the top, as a new install. An update from
  #    build A to B needs A's depot manifests; SteamCMD keeps them in its depotcache (kept on this
  #    volume, see the top), and when they are gone Steam will NOT hand an old manifest to an
  #    anonymous login ("Failed to get manifest request code, 'Access Denied'"), so nothing short
  #    of a fresh install gets past it. Measured: the whole 6 GB again, about 10 GB on the disk at
  #    the peak, a minute or two. Never for a network failure, which a re-download cannot fix.
  # Then the build already installed is started anyway: a server on the old build is still better
  # than none, and the update watch tries again later.
  local ok=0 validate out="${FLUX_RUN_DIR}/steamcmd.out"
  for attempt in 1 2 3; do
    validate=""
    case "${attempt}" in
      2) validate="validate" ;;
      3)
        grep -q "state is 0x6" "${out}" 2>/dev/null || break
        flux_log "updating as a new install: Steam no longer serves the installed build's manifests"
        rm -rf "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf" "${s}/steamapps/downloading" "${s}/steamapps/temp"
        ;;
    esac
    # shellcheck disable=SC2086  # validate is "" or "validate"
    steamcmd +force_install_dir "${s}" +login anonymous +app_update "${FLUX_STEAM_APP}" "${beta[@]}" ${validate} +quit \
      2>&1 | tee "${out}"
    if [ "${PIPESTATUS[0]}" = "0" ] && [ -x "${s}/${FLUX_GAME_BINARY}" ]; then
      ok=1
      break
    fi
    [ "${terminating}" = "1" ] && return 1
    flux_log "WARN steamcmd failed (attempt ${attempt})"
    disk_note
    sleep 5
  done
  if [ ! -x "${s}/${FLUX_GAME_BINARY}" ]; then
    flux_log "ERROR could not install the server from Steam"
    return 1
  fi
  local after
  after="$(flux_acf_buildid "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
  if [ "${ok}" = "0" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed (${after:-unknown})"
  else
    flux_log "Rust build ${after:-unknown} installed"
  fi
  return 0
}

# Fetches the Carbon release FLUX_CARBON_TAG points at into the cache, unless it is there.
# Prints the version to use, or nothing when there is none (no network and nothing cached).
carbon_release() {
  local cache="${FLUX_STATE_DIR}/carbon" info version tmp
  mkdir -p "${cache}"
  info="$(curl -fsSL --max-time 30 "${FLUX_CARBON_URL}/${FLUX_CARBON_TAG}/Carbon.Linux.Release.info" 2>/dev/null)"
  version="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("InformationalVersion",""))' <<<"${info}" 2>/dev/null)"
  if [ -z "${version}" ] || ! flux_carbon_version_ok "${version}"; then
    version="$(flux_carbon_cached "${cache}")"
    [ -n "${version}" ] && flux_log "WARN could not read the current Carbon release; using the cached Carbon ${version}" >&2
    printf '%s' "${version}"
    return 0
  fi
  if [ ! -f "${cache}/${version}/carbon/${FLUX_CARBON_MARKER}" ]; then
    flux_log "downloading Carbon ${version}" >&2
    tmp="${cache}/.download-$$"
    rm -rf "${tmp}" && mkdir -p "${tmp}/x"
    if curl -fsSL --max-time 300 -o "${tmp}/carbon.tar.gz" \
        "${FLUX_CARBON_URL}/${FLUX_CARBON_TAG}/Carbon.Linux.Release.tar.gz" \
      && tar -xzf "${tmp}/carbon.tar.gz" -C "${tmp}/x" \
      && [ -f "${tmp}/x/carbon/${FLUX_CARBON_MARKER}" ] && [ -f "${tmp}/x/libdoorstop.so" ]; then
      rm -rf "${cache:?}/${version}"
      mv "${tmp}/x" "${cache}/${version}"
    else
      flux_log "WARN the Carbon ${version} download failed" >&2
      version="$(flux_carbon_cached "${cache}")"
      [ -n "${version}" ] && flux_log "WARN using the cached Carbon ${version}" >&2
    fi
    rm -rf "${tmp}"
  fi
  flux_carbon_prune "${cache}" "${version}"
  printf '%s' "${version}"
}

# Sets GAME_ENV (the variables RustDedicated starts with) and writes FLUX_CARBON_ACTIVE.
prepare_framework() {
  local version release
  GAME_ENV=("LD_LIBRARY_PATH=${s}:${s}/RustDedicated_Data/Plugins:${s}/RustDedicated_Data/Plugins/x86_64")
  printf 'none' >"${FLUX_CARBON_ACTIVE}"
  [ "${framework}" = "carbon" ] || return 0
  version="$(carbon_release)"
  if [ -z "${version}" ]; then
    flux_log "ERROR no Carbon release could be downloaded and none is cached: starting WITHOUT plugins. The update watcher retries."
    return 0
  fi
  release="${FLUX_STATE_DIR}/carbon/${version}"
  if ! flux_carbon_install "${release}/carbon" "${FLUX_CARBON_DIR}" \
    || ! cp -f "${release}/libdoorstop.so" "${s}/libdoorstop.so"; then
    flux_log "ERROR could not install Carbon ${version} into ${FLUX_CARBON_DIR}: starting WITHOUT plugins"
    return 0
  fi
  # Before every start: an owner can turn it back on from the file browser.
  local note
  if ! note="$(flux_carbon_disable_selfupdate "${FLUX_CARBON_DIR}/config.json" 2>&1)"; then
    flux_log "ERROR could not turn Carbon's self-updater off (${note}): starting WITHOUT plugins, Carbon would hang at boot"
    return 0
  fi
  [ -n "${note}" ] && flux_log "Carbon: ${note}"
  # What carbon/tools/environment.sh exports, written out: sourcing it here would put the
  # preload into the supervisor's own environment, and every tool it runs would load it.
  GAME_ENV+=(
    "DOORSTOP_ENABLED=1"
    "DOORSTOP_TARGET_ASSEMBLY=${FLUX_CARBON_DIR}/managed/Carbon.Preloader.dll"
    "LD_PRELOAD=${s}/libdoorstop.so"
    "TERM=xterm"
  )
  printf '%s' "${version}" >"${FLUX_CARBON_ACTIVE}"
  flux_log "Carbon ${version}"
}

# Before every start, not only the first: a crash or a kill mid-save cuts a save just the same.
recover_saves() {
  local identity line
  identity="$(flux_arg_value server.identity "${GAME_ARGS[@]+"${GAME_ARGS[@]}"}")"
  [ -n "${identity}" ] || identity="my_server_identity"
  [[ "${identity}" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  [ -d "${s}/server/${identity}" ] || return 0
  while IFS= read -r line; do
    [ -n "${line}" ] && flux_log "WARN the last save was cut off while it was being written: ${line}"
  done < <(flux_recover_interrupted_saves "${s}/server/${identity}")
}

start_generation() {
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}" "${FLUX_STARTED_AT}"
  update_server || return 1
  [ "${terminating}" = "1" ] && return 2
  prepare_framework
  [ "${terminating}" = "1" ] && return 2
  disk_note
  recover_saves
  flux_log "starting the server (generation ${generation})"
  date -u +%s >"${FLUX_STARTED_AT}"
  (
    cd "${s}" || exit 1
    exec env "${GAME_ENV[@]}" "./${FLUX_GAME_BINARY}" -batchmode -nographics "${GAME_ARGS[@]}"
  ) &
  game_pid=$!
  return 0
}

# Waits for the game to end. A planned restart that is not honoured within FLUX_STOP_GRACE ends it
# by force; the grace runs from when the request was first seen. Sets game_rc.
wait_for_generation() {
  local asked_at=0 now
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 1 &
    wait $!
    if [ "${terminating}" != "1" ] && [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        kill -KILL "${game_pid}" 2>/dev/null
        break
      fi
    fi
  done
  # `wait` returns early when a trap fires, so ask again until the child is gone.
  while true; do
    wait "${game_pid}" 2>/dev/null
    game_rc=$?
    kill -0 "${game_pid}" 2>/dev/null || break
  done
  game_pid=""
  local left
  left="$(flux_kill_leftover_games)"
  [ -n "${left}" ] && flux_log "WARN ${left} game process(es) outlived the server; ended them"
}

/opt/flux/flux-updatewatch.sh &
/opt/flux/flux-scheduler.sh &

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    exit 42
  fi
  wait_for_generation
  rc="${game_rc}"
  rm -f "${FLUX_STARTED_AT}"

  reason=""
  [ -f "${FLUX_RESTART_MARKER}" ] && reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    exit 0
  fi

  # RustDedicated ends with 0 when it was told to quit (an admin's `quit` over RCON): that is a
  # restart someone asked for.
  if [ -z "${reason}" ] && [ "${rc}" = "0" ]; then
    reason="requested: the server quit (exit 0)"
  fi
  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      exit 42
    fi
  fi

  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
