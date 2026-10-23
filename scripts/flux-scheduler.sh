#!/bin/bash
# The daily restart, if one is set.
#
#   FLUX_RESTART_TIME          HH:MM, 24 hour, in the container's TZ. Empty = no daily restart.
#   FLUX_RESTART_WARN_MINUTES  how long before it players are warned (0..30, default 5)
#
# A restart saves the world, frees what a long-running Rust server holds on to, and updates the
# server (SteamCMD runs before every start), so a daily one keeps a server healthy and current
# even with the update watch turned off.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

target="$(flux_restart_minute_of_day "${FLUX_RESTART_TIME:-}")" || {
  [ -n "${FLUX_RESTART_TIME:-}" ] && flux_log "WARN FLUX_RESTART_TIME='${FLUX_RESTART_TIME}' is not HH:MM; no daily restart"
  exit 0
}
warn="$(flux_warn_minutes "${FLUX_RESTART_WARN_MINUTES:-5}")"

while true; do
  # The restart as an absolute time, computed once a day, so the countdown cannot roll over to
  # tomorrow halfway through.
  now_h=0 now_m=0 now_s=0
  IFS=: read -r now_h now_m now_s <<<"$(date +%H:%M:%S)"
  due=$(($(date +%s) + $(flux_seconds_until "${target}" $((10#${now_h} * 60 + 10#${now_m})) $((10#${now_s})))))
  flux_log "daily restart at ${FLUX_RESTART_TIME} (${TZ:-UTC}), in $(((due - $(date +%s)) / 60)) minutes, with a ${warn} minute warning"

  # Sleeps in steps of at most five minutes, so a clock that moves is noticed.
  while :; do
    left=$((due - warn * 60 - $(date +%s)))
    [ "${left}" -le 0 ] && break
    sleep $((left > 300 ? 300 : left))
  done

  /opt/flux/flux-restart.sh "scheduled restart at ${FLUX_RESTART_TIME}" "${warn}" "daily restart"
  # Past the minute it was due in, so the next pass schedules tomorrow's.
  sleep 120
done
