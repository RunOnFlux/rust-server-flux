#!/bin/bash
# shellcheck disable=SC2016  # the conditions are eval'd by wait_for, later, on purpose
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t.
#
# No Steam, no game, no GitHub: a stand-in steamcmd "installs" a stand-in RustDedicated and
# answers app_info_print with whatever build the test says is current, and Carbon comes from a
# file:// release built here. The real supervisor and the real helpers run around them.
set -uo pipefail
export LC_ALL=C
cd / || exit 1

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
wait_for() { # condition, seconds
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 envsubst flock curl pgrep tar; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "flux-rcon is on the PATH" "0" "$(status command -v flux-rcon)"
check "flux-restart is on the PATH" "0" "$(status command -v flux-restart)"
for script in /opt/flux/*.sh; do
  check "${script##*/} parses" "0" "$(status bash -n "${script}")"
done
check "flux-steam.py parses in the image's Python" "0" "$(status python3 -m py_compile /opt/flux/flux-steam.py)"
check "flux-rcon.py parses in the image's Python" "0" "$(status python3 -m py_compile /opt/flux/flux-rcon.py)"

# --- Stand-ins ---------------------------------------------------------------------------------
stub=/tmp/stub
mkdir -p "${stub}/bin"
cat >"${stub}/RustDedicated" <<'EOF'
#!/bin/bash
# Stand-in RustDedicated: records how it was started, saves and exits 0 on TERM, crashes on demand.
env | grep -E '^(LD_PRELOAD|DOORSTOP_ENABLED|DOORSTOP_TARGET_ASSEMBLY)=' | sort >/tmp/stub/env.$$
printf '%s\n' "$@" >/tmp/stub/args
echo "$$" >>/tmp/stub/starts
trap 'echo saved >>/tmp/stub/saves; exit 0' TERM
echo "Server startup complete"
# A forked child that never ends, like the Mono fork that never reaches exec.
if [ -f /tmp/stub/fork ]; then
  rm -f /tmp/stub/fork
  (trap '' TERM; while :; do sleep 0.2; done) &
fi
while sleep 0.2; do
  [ -f /tmp/stub/crash ] && { rm -f /tmp/stub/crash; exit 139; }
done
EOF
chmod +x "${stub}/RustDedicated"
cat >"${stub}/bin/steamcmd" <<'EOF'
#!/bin/bash
# Stand-in steamcmd: app_update installs the stand-in game at the "current" build; app_info_print
# lists the build in /tmp/stub/latest.
dir=""; prev=""
for a in "$@"; do
  [ "${prev}" = "+force_install_dir" ] && dir="${a}"
  prev="${a}"
done
case " $* " in
  *" +app_update "*)
    [ -f /tmp/stub/steam-down ] && exit 8
    echo "app_update $*" >>/tmp/stub/steam-calls
    mkdir -p "${dir}/steamapps"
    cp /tmp/stub/RustDedicated "${dir}/RustDedicated"
    printf '"AppState"\n{\n\t"buildid"\t\t"%s"\n}\n' "$(cat /tmp/stub/latest)" >"${dir}/steamapps/appmanifest_258550.acf"
    ;;
  *" +app_info_print "*)
    printf '"258550"\n{\n"depots"\n{\n"branches"\n{\n"public"\n{\n"buildid" "%s"\n}\n}\n}\n}\n' "$(cat /tmp/stub/latest)"
    ;;
esac
exit 0
EOF
chmod +x "${stub}/bin/steamcmd"
echo 1000 >"${stub}/latest"

# A Carbon release, served over file://.
rel=/tmp/carbon-release
mkdir -p "${rel}/production_build" "${rel}/x/carbon/"{managed,tools,native,plugins,configs}
echo 'export DOORSTOP_ENABLED=1' >"${rel}/x/carbon/tools/environment.sh"
echo dll >"${rel}/x/carbon/managed/Carbon.Preloader.dll"
echo so >"${rel}/x/libdoorstop.so"
tar -czf "${rel}/production_build/Carbon.Linux.Release.tar.gz" -C "${rel}/x" .
echo '{"InformationalVersion": "9.9.1-test"}' >"${rel}/production_build/Carbon.Linux.Release.info"

export PATH="${stub}/bin:${PATH}"
export FLUX_CARBON_URL="file://${rel}"
export FLUX_RESTART_BACKOFF=1
export FLUX_UPDATE_BOOT_GRACE=0
export RCON_PASSWORD=pw

run_supervisor() { # extra env assignments...
  rm -rf /srv/rust /tmp/flux "${stub}/starts" "${stub}/saves" "${stub}/steam-calls" "${stub}"/env.*
  mkdir -p /srv/rust
  [ -n "${SEED_WORLD:-}" ] && "${SEED_WORLD}"
  env "$@" /opt/flux/flux-entrypoint.sh +rcon.port 28016 +rcon.password '${RCON_PASSWORD}' +server.identity test \
    >/tmp/supervisor.log 2>&1 &
  sup=$!
}
starts() { if [ -f "${stub}/starts" ]; then wc -l <"${stub}/starts"; else echo 0; fi; }
stop_supervisor() { # sets stopped_rc; never in $(...), where the supervisor is not a child
  kill -TERM "${sup}" 2>/dev/null
  wait_for "! kill -0 ${sup} 2>/dev/null" 15
  wait "${sup}" 2>/dev/null
  stopped_rc=$?
}

# --- Vanilla: installed from "Steam", started without Carbon -----------------------------------
run_supervisor FLUX_FRAMEWORK=
check "vanilla: the server starts" "0" "$(wait_for '[ "$(starts)" -ge 1 ]' 20; echo $?)"
check "vanilla: installed by steamcmd" "1" "$(grep -c app_update "${stub}/steam-calls")"
check "vanilla: no preload" "" "$(cat "${stub}"/env.* 2>/dev/null)"
check "vanilla: \${RCON_PASSWORD} expanded in the arguments" "+rcon.password pw" "$(sed -n '5,6p' "${stub}/args" | paste -sd' ')"
check "vanilla: RCON details left for flux-rcon" "RCON_PORT=28016" "$(head -1 /tmp/flux/rcon.env)"
check "vanilla: the depotcache lives on the install volume" "/srv/rust/.flux/depotcache" \
  "$(readlink /root/.local/share/Steam/depotcache)"
check "vanilla: carbon-active says none" "none" "$(cat /tmp/flux/carbon-active)"

# A planned restart: a new generation, updated first, not counted as a crash.
flux-restart "planned: test" 0 >/dev/null 2>&1
check "planned restart: a second generation" "0" "$(wait_for '[ "$(starts)" -ge 2 ]' 20; echo $?)"
check "planned restart: the world was saved" "1" "$(wc -l <"${stub}/saves")"
check "planned restart: updated before the start" "2" "$(grep -c app_update "${stub}/steam-calls")"
check "planned restart: logged as planned" "1" "$(grep -c 'planned: test: restarting the server in place' /tmp/supervisor.log)"

# Docker's stop: saved, and the container ends with 0.
stop_supervisor
check "stop: the container ends with 0" "0" "${stopped_rc}"
check "stop: the world was saved" "2" "$(wc -l <"${stub}/saves")"

# --- A save cut off mid-write is repaired before the start --------------------------------------
cut_save() {
  local w=/srv/rust/server/test
  mkdir -p "${w}"
  printf 'whole' >"${w}/proceduralmap.4500.1.289.sav.new"
  printf 'cut' >"${w}/proceduralmap.4500.1.289.sav"
  touch -d '2026-10-17 15:55:45.603' "${w}/proceduralmap.4500.1.289.sav.new"
  touch -d '2026-10-17 15:55:45.653' "${w}/proceduralmap.4500.1.289.sav"
}
SEED_WORLD=cut_save run_supervisor FLUX_FRAMEWORK=
check "cut save: the server starts" "0" "$(wait_for '[ "$(starts)" -ge 1 ]' 20; echo $?)"
check "cut save: the whole copy is the .sav" "whole" "$(cat /srv/rust/server/test/proceduralmap.4500.1.289.sav)"
check "cut save: no .sav.new left" "1" "$(status test -e /srv/rust/server/test/proceduralmap.4500.1.289.sav.new)"
check "cut save: logged" "1" "$(grep -c 'the last save was cut off while it was being written: restored' /tmp/supervisor.log)"
stop_supervisor

# --- Carbon: fetched, cached, preloaded --------------------------------------------------------
run_supervisor FLUX_FRAMEWORK=carbon
check "carbon: the server starts" "0" "$(wait_for '[ "$(starts)" -ge 1 ]' 20; echo $?)"
check "carbon: the release is cached on the install volume" "0" "$(status test -f /srv/rust/.flux/carbon/9.9.1-test/carbon/tools/environment.sh)"
check "carbon: the tree is seeded" "0" "$(status test -f /srv/rust/carbon/managed/Carbon.Preloader.dll)"
check "carbon: doorstop next to the game" "0" "$(status test -f /srv/rust/libdoorstop.so)"
check "carbon: preloaded" "DOORSTOP_ENABLED=1|DOORSTOP_TARGET_ASSEMBLY=/srv/rust/carbon/managed/Carbon.Preloader.dll|LD_PRELOAD=/srv/rust/libdoorstop.so" \
  "$(cat "${stub}"/env.* | paste -sd'|')"
check "carbon: carbon-active names the version" "9.9.1-test" "$(cat /tmp/flux/carbon-active)"
check "carbon: the supervisor itself is not preloaded" "" "$(tr '\0' '\n' </proc/${sup}/environ | grep LD_PRELOAD)"
check "carbon: the self-updater is off before the first start" "False" \
  "$(python3 -c 'import json; print(json.load(open("/srv/rust/carbon/config.json"))["SelfUpdating"]["Enabled"])')"
# Turned back on (or Carbon's defaults): off again at the next start.
python3 -c 'import json; json.dump({"Rcon": True, "SelfUpdating": {"Enabled": True}}, open("/srv/rust/carbon/config.json", "w"))'
flux-restart "planned: test" 0 >/dev/null 2>&1
wait_for '[ "$(starts)" -ge 2 ]' 20
check "carbon: off again at every start" "False True" \
  "$(python3 -c 'import json; c=json.load(open("/srv/rust/carbon/config.json")); print(c["SelfUpdating"]["Enabled"], c["Rcon"])')"
check "carbon: logged" "1" "$(grep -c "Carbon: turned Carbon's self-updater off" /tmp/supervisor.log)"
stop_supervisor

# Carbon unreachable, but cached: still a Carbon server.
mkdir -p /tmp/keep && cp -a /srv/rust/.flux /tmp/keep/
rm -rf /srv/rust && mkdir -p /srv/rust && cp -a /tmp/keep/.flux /srv/rust/
env FLUX_FRAMEWORK=carbon FLUX_CARBON_URL=file:///nonexistent /opt/flux/flux-entrypoint.sh +server.identity test >/tmp/supervisor.log 2>&1 &
sup=$!
check "carbon offline: starts from the cache" "0" "$(wait_for 'grep -q "using the cached Carbon 9.9.1-test" /tmp/supervisor.log' 20; echo $?)"
stop_supervisor

# --- The update watch: a new build means a warned restart onto it -------------------------------
run_supervisor FLUX_FRAMEWORK= FLUX_UPDATE_CHECK_SECONDS=1 FLUX_UPDATE_WARN_MINUTES=0
wait_for '[ "$(starts)" -ge 1 ]' 20
echo 1001 >"${stub}/latest"
check "watch: restarts for the new build" "0" "$(wait_for '[ "$(starts)" -ge 2 ]' 30; echo $?)"
check "watch: logged why" "0" "$(status grep -q 'update: Rust build 1001 is out (installed 1000)' /tmp/supervisor.log)"
check "watch: the new build is installed" "1001" "$(sed -n 's/.*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' /srv/rust/steamapps/appmanifest_258550.acf)"
sleep 3
check "watch: no second restart once current" "2" "$(starts)"
stop_supervisor

# Steam down at the restart: the old build starts, and the same update is not retried at once.
run_supervisor FLUX_FRAMEWORK= FLUX_UPDATE_CHECK_SECONDS=1 FLUX_UPDATE_WARN_MINUTES=0
wait_for '[ "$(starts)" -ge 1 ]' 20
touch "${stub}/steam-down"
echo 1002 >"${stub}/latest"
check "steam down: the restart still starts the server" "0" "$(wait_for '[ "$(starts)" -ge 2 ]' 60; echo $?)"
check "steam down: said so" "1" "$(grep -c 'could not update from Steam; starting the build already installed' /tmp/supervisor.log)"
sleep 4
check "steam down: not retried within the hour" "2" "$(starts)"
rm -f "${stub}/steam-down"
stop_supervisor

# --- Crashes: restarted in place, until the budget runs out ------------------------------------
run_supervisor FLUX_FRAMEWORK= FLUX_RESTART_MAX_ATTEMPTS=1 FLUX_AUTO_UPDATE=false
wait_for '[ "$(starts)" -ge 1 ]' 20
touch "${stub}/crash"
check "crash: restarted in place" "0" "$(wait_for '[ "$(starts)" -ge 2 ]' 20; echo $?)"
touch "${stub}/crash"
wait_for "! kill -0 ${sup} 2>/dev/null" 20
wait "${sup}" 2>/dev/null
check "crash: over the budget the container ends with 42" "42" "$?"
check "auto update off is said once" "1" "$(grep -c 'automatic updates are off' /tmp/supervisor.log)"

# A child the game forked dies with it, before the next generation starts.
touch "${stub}/fork"
run_supervisor FLUX_FRAMEWORK= FLUX_AUTO_UPDATE=false
wait_for '[ "$(starts)" -ge 1 ]' 20
check "leftover: the stand-in forked" "0" "$(wait_for '[ "$(pgrep -c -x RustDedicated)" -ge 2 ]' 10; echo $?)"
touch "${stub}/crash"
wait_for '[ "$(starts)" -ge 2 ]' 20
sleep 1
check "leftover: one game process after the restart" "1" "$(pgrep -c -x RustDedicated)"
check "leftover: logged" "1" "$(grep -c '1 game process(es) outlived the server; ended them' /tmp/supervisor.log)"
stop_supervisor

# --- Bad settings refuse to start --------------------------------------------------------------
check "FLUX_FRAMEWORK=oxide refuses to start" "42" "$(FLUX_FRAMEWORK=oxide /opt/flux/flux-entrypoint.sh >/dev/null 2>&1; echo $?)"
check "a bad STEAM_BRANCH refuses to start" "42" "$(STEAM_BRANCH='a b' /opt/flux/flux-entrypoint.sh >/dev/null 2>&1; echo $?)"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || { echo '--- last supervisor log ---'; tail -40 /tmp/supervisor.log; exit 1; }
