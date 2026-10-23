#!/bin/bash
# Restarts the server onto a new Rust build (or a new Carbon release) as soon as one is out.
#
#   FLUX_AUTO_UPDATE            on unless false/0/no/off
#   FLUX_UPDATE_CHECK_MINUTES   how often Steam is asked (2..1440, default 10)
#   FLUX_UPDATE_WARN_MINUTES    how long players are warned first (0..30, default 5)
#
# Facepunch's clients refuse a server on an older build ("Wrong Connection Protocol: Server update
# required!"), so a server that waits for its next restart is a server nobody can join. The update
# itself is the supervisor's: this only notices that one is due and asks for the restart.
#
# A Carbon server also restarts for a new Carbon release, because after a Rust update the old
# Carbon is the one most likely to break, and for Carbon itself when it could not be fetched at
# the last start. An update that did not take (Steam unreachable from this node) is retried after
# an hour, then two, then three: every retry is a restart in front of the players.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

if [ -n "${FLUX_AUTO_UPDATE:-}" ] && ! flux_truthy "${FLUX_AUTO_UPDATE}"; then
  flux_log "automatic updates are off (FLUX_AUTO_UPDATE=${FLUX_AUTO_UPDATE}): a new Rust build waits for a restart"
  exit 0
fi

every="$(flux_check_minutes "${FLUX_UPDATE_CHECK_MINUTES:-10}")"
# Seconds, for the image tests only: a real server is never asked more often than every 2 minutes.
every_s="${FLUX_UPDATE_CHECK_SECONDS:-$((every * 60))}"
warn="$(flux_warn_minutes "${FLUX_UPDATE_WARN_MINUTES:-5}")"
grace="${FLUX_UPDATE_BOOT_GRACE:-900}"
retry_after="${FLUX_UPDATE_RETRY_AFTER:-3600}"
branch="${FLUX_BRANCH:-public}"
framework="$(flux_framework "${FLUX_FRAMEWORK:-}" 2>/dev/null)" || framework=vanilla
attempt_file="${FLUX_STATE_DIR}/update-attempt"
acf="${FLUX_SERVER_DIR}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf"

flux_log "update watch: Steam checked every ${every} minutes, players warned ${warn} minutes before"

latest_carbon() {
  curl -fsSL --max-time 30 "${FLUX_CARBON_URL}/${FLUX_CARBON_TAG}/Carbon.Linux.Release.info" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("InformationalVersion",""))' 2>/dev/null
}

while true; do
  sleep "${every_s}"

  [ -n "$(flux_game_pid)" ] || continue
  [ -f "${FLUX_RESTART_MARKER}" ] && continue
  if flux_booting "$(cat "${FLUX_STARTED_AT}" 2>/dev/null)" "$(date -u +%s)" "${grace}"; then
    continue
  fi

  why=()
  target=""
  installed="$(flux_acf_buildid "${acf}")"
  if latest="$(python3 /opt/flux/flux-steam.py buildid "${FLUX_STEAM_APP}" "${branch}" 2>/dev/null)" \
    && flux_build_is_new "${installed}" "${latest}"; then
    why+=("Rust build ${latest} is out (installed ${installed:-none})")
    target="rust:${latest}"
  fi

  if [ "${framework}" = "carbon" ]; then
    active="$(cat "${FLUX_CARBON_ACTIVE}" 2>/dev/null)"
    carbon="$(latest_carbon)"
    if flux_carbon_version_ok "${carbon}" && [ "${carbon}" != "${active}" ]; then
      why+=("Carbon ${carbon} is out (running ${active:-none})")
      target="${target} carbon:${carbon}"
    fi
  fi

  [ "${#why[@]}" -gt 0 ] || continue

  now="$(date -u +%s)"
  # The target is written with its spaces as "+", so it reads back as one word. The same target
  # again waits retry_after, then twice that, and so on: an update that does not take on this
  # node must not become a restart every hour in front of the players.
  read -r last_target last_at tries <<<"$(tr '\n' ' ' <"${attempt_file}" 2>/dev/null)"
  if [ "${last_target:-}" = "${target// /+}" ]; then
    tries="${tries:-1}"
    [[ "${tries}" =~ ^[0-9]+$ ]] || tries=1
    [ $((now - ${last_at:-0})) -lt $((retry_after * tries)) ] && continue
    tries=$((tries + 1))
  else
    tries=1
  fi
  printf '%s %s %s\n' "${target// /+}" "${now}" "${tries}" >"${attempt_file}"

  joined="$(printf '%s; ' "${why[@]}")"
  reason="update: ${joined%; }"
  flux_log "${reason}"
  /opt/flux/flux-restart.sh "${reason}" "${warn}" "installing the new Rust update"
done
