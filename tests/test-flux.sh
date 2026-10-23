#!/bin/bash
# shellcheck disable=SC2016  # '${VARS}' are expanded by flux_expand_args, which is the point
# Unit tests for the pure parts of the scripts: no Docker, no Steam, no game.
#
#   ./tests/test-flux.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C

FLUX_LOG=""
# shellcheck source=scripts/flux-lib.sh
source scripts/flux-lib.sh

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

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- FLUX_FRAMEWORK ------------------------------------------------------------------------------
check "empty framework is vanilla" "vanilla" "$(flux_framework '')"
check "vanilla" "vanilla" "$(flux_framework vanilla)"
check "none is vanilla" "vanilla" "$(flux_framework none)"
check "carbon" "carbon" "$(flux_framework carbon)"
check "Carbon, any case" "carbon" "$(flux_framework CARBON)"
check "oxide is refused (it cannot compile on Flux)" "1" "$(status flux_framework oxide)"

# --- STEAM_BRANCH --------------------------------------------------------------------------------
check "empty branch is public" "public" "$(flux_steam_branch '')"
check "a named branch" "staging" "$(flux_steam_branch staging)"
check "a branch with a space is refused" "1" "$(status flux_steam_branch 'a b')"
check "a branch with a quote is refused" "1" "$(status flux_steam_branch 'x"')"

# --- appmanifest ---------------------------------------------------------------------------------
cat >"${tmp}/app.acf" <<'EOF'
"AppState"
{
	"appid"		"258550"
	"StateFlags"		"4"
	"buildid"		"26139947"
	"TargetBuildID"		"26139947"
	"InstalledDepots"
	{
	}
}
EOF
check "build id from the manifest" "26139947" "$(flux_acf_buildid "${tmp}/app.acf")"
check "no manifest, no build id" "" "$(flux_acf_buildid "${tmp}/missing.acf")"

check "a different build is new" "0" "$(status flux_build_is_new 26000000 26139947)"
check "an older build listed is new too (a rollback)" "0" "$(status flux_build_is_new 26139947 26000000)"
check "the same build is not new" "1" "$(status flux_build_is_new 26139947 26139947)"
check "nothing installed: any build is new" "0" "$(status flux_build_is_new '' 26139947)"
check "an unreadable answer is not new" "1" "$(status flux_build_is_new 26139947 '')"
check "garbage is not new" "1" "$(status flux_build_is_new 26139947 'error')"

# --- server arguments ----------------------------------------------------------------------------
args=(+rcon.port 28016 +rcon.password 'p@ss word' +server.identity rustcarbon -queryport 28017)
check "rcon.port from the arguments" "28016" "$(flux_arg_value rcon.port "${args[@]}")"
check "rcon.password keeps its spaces" "p@ss word" "$(flux_arg_value rcon.password "${args[@]}")"
check "an absent convar is empty" "" "$(flux_arg_value server.seed "${args[@]}")"
check "the last one wins" "2" "$(flux_arg_value a +a 1 +a 2)"
check "a convar at the very end has no value" "" "$(flux_arg_value a x +a)"

check "a port" "28016" "$(flux_valid_port 28016)"
check "leading zeros" "80" "$(flux_valid_port 0080)"
check "too large" "1" "$(status flux_valid_port 70000)"
check "not a number" "1" "$(status flux_valid_port abc)"

export RCON_PASSWORD='s3cret'
flux_expand_args +rcon.password '${RCON_PASSWORD}' +server.hostname 'plain'
check "\${VARS} in the arguments are expanded" "+rcon.password s3cret +server.hostname plain" "${FLUX_EXPANDED_ARGS[*]}"

# --- scheduled restarts --------------------------------------------------------------------------
check "05:00" "300" "$(flux_restart_minute_of_day 05:00)"
check "5:30" "330" "$(flux_restart_minute_of_day 5:30)"
check "24:00 is refused" "1" "$(status flux_restart_minute_of_day 24:00)"
check "empty is no restart" "1" "$(status flux_restart_minute_of_day '')"
check "an hour ahead" "3600" "$(flux_seconds_until 360 300 0)"
check "this very minute is tomorrow's" "86400" "$(flux_seconds_until 300 300 0)"
check "past today is tomorrow" "$((86400 - 3600))" "$(flux_seconds_until 300 360 0)"
check "warn default" "5" "$(flux_warn_minutes '')"
check "warn capped" "30" "$(flux_warn_minutes 90)"
check "warn garbage" "5" "$(flux_warn_minutes x)"
check "check interval default" "10" "$(flux_check_minutes '')"
check "check interval floor" "2" "$(flux_check_minutes 0)"
check "check interval cap" "1440" "$(flux_check_minutes 99999)"

check "booting inside the grace" "0" "$(status flux_booting 1000 1500 900)"
check "past the grace" "1" "$(status flux_booting 1000 2000 900)"
check "no start time is booting" "0" "$(status flux_booting '' 2000 900)"

# --- restart budget ------------------------------------------------------------------------------
check "restarts in the window" "900 950" "$(flux_restarts_in_window 1000 200 700 900 950)"
check "a crash counts" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "an update does not" "1" "$(status flux_restart_counts 'update: Rust build 1 is out')"
check "the daily restart does not" "1" "$(status flux_restart_counts 'scheduled restart at 05:00')"
check "an admin's quit does not" "1" "$(status flux_restart_counts 'requested: the server quit (exit 0)')"

# --- Carbon --------------------------------------------------------------------------------------
release="${tmp}/release/carbon"
mkdir -p "${release}"/{managed,tools,native,plugins,configs}
echo new >"${release}/managed/Carbon.dll"
echo env >"${release}/tools/environment.sh"
echo default >"${release}/configs/config.json"
tree="${tmp}/tree"
check "an empty tree needs seeding" "0" "$(status flux_carbon_needs_seed "${tree}")"
flux_carbon_install "${release}" "${tree}"
check "seeding copies the runtime" "new" "$(cat "${tree}/managed/Carbon.dll")"
check "seeding copies the default configs" "default" "$(cat "${tree}/configs/config.json")"
check "seeding creates the user folders" "0" "$(status test -d "${tree}/lang")"
echo mine >"${tree}/configs/config.json"
echo plugin >"${tree}/plugins/Mine.cs"
echo stale >"${tree}/managed/Old.dll"
echo newer >"${release}/managed/Carbon.dll"
flux_carbon_install "${release}" "${tree}"
check "a refresh replaces the runtime" "newer" "$(cat "${tree}/managed/Carbon.dll")"
check "a refresh drops runtime files the release no longer has" "1" "$(status test -e "${tree}/managed/Old.dll")"
check "a refresh keeps the owner's configs" "mine" "$(cat "${tree}/configs/config.json")"
check "a refresh keeps the owner's plugins" "plugin" "$(cat "${tree}/plugins/Mine.cs")"

cache="${tmp}/cache"
mkdir -p "${cache}/v1/carbon/tools" "${cache}/v2/carbon/tools" "${cache}/v3/carbon" "${cache}/.download-1"
touch "${cache}/v1/carbon/tools/environment.sh" "${cache}/v1/libdoorstop.so"
sleep 1
touch "${cache}/v2/carbon/tools/environment.sh" "${cache}/v2/libdoorstop.so"
touch -d '1 hour ago' "${cache}/v1"
check "the newest complete release is the one cached" "v2" "$(flux_carbon_cached "${cache}")"
flux_carbon_prune "${cache}" "v1"
check "prune keeps the one in use" "0" "$(status test -d "${cache}/v1")"
check "prune keeps the newest" "0" "$(status test -d "${cache}/v2")"
check "prune drops an incomplete release" "1" "$(status test -d "${cache}/v3")"
check "prune drops a half download" "1" "$(status test -d "${cache}/.download-1")"
check "a version is a folder name" "0" "$(status flux_carbon_version_ok 2.0.262-ReleaseUnix-production-8a81d70)"
check "a path is not a version" "1" "$(status flux_carbon_version_ok ../x)"
check "empty is not a version" "1" "$(status flux_carbon_version_ok '')"

cfg="${tmp}/carbon-config.json"
check "no config: one is written" "created carbon-config.json with the self-updater off" "$(flux_carbon_disable_selfupdate "${cfg}")"
check "no config: self-updater off" "False" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["SelfUpdating"]["Enabled"])' "${cfg}")"
printf '\xef\xbb\xbf{"Rcon": true, "SelfUpdating": {"Enabled": true, "HookUpdates": true}, "Language": "en"}' >"${cfg}"
check "a config with it on (and a BOM): turned off" "turned Carbon's self-updater off" "$(flux_carbon_disable_selfupdate "${cfg}")"
check "the owner's other settings are kept" "True en True" \
  "$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(c["Rcon"], c["Language"], c["SelfUpdating"]["HookUpdates"])' "${cfg}")"
check "already off: nothing to say" "" "$(flux_carbon_disable_selfupdate "${cfg}")"
before="$(stat -c %Y.%s "${cfg}")"
check "already off: the file is not rewritten" "${before}" "$(stat -c %Y.%s "${cfg}")"
echo '{"broken' >"${cfg}"
check "not JSON: said so" "1" "$(flux_carbon_disable_selfupdate "${cfg}" | grep -c 'was not valid JSON')"
check "not JSON: set aside" "1" "$(find "${tmp}" -name 'carbon-config.json.broken.*' | wc -l)"
check "not JSON: replaced with one that has it off" "False" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["SelfUpdating"]["Enabled"])' "${cfg}")"

# --- interrupted saves ---------------------------------------------------------------------------
w="${tmp}/world"
mkdir -p "${w}"
# Cut while replacing .sav (the 2026-10-17 case): .sav is 50 ms newer and truncated.
printf 'whole' >"${w}/proceduralmap.4500.1337.289.sav.new"
printf 'cut' >"${w}/proceduralmap.4500.1337.289.sav"
touch -d '2026-10-17 15:55:45.603' "${w}/proceduralmap.4500.1337.289.sav.new"
touch -d '2026-10-17 15:55:45.653' "${w}/proceduralmap.4500.1337.289.sav"
out="$(flux_recover_interrupted_saves "${w}")"
check "a .sav cut while being replaced is restored from .sav.new" "whole" "$(cat "${w}/proceduralmap.4500.1337.289.sav")"
check "and says so" "restored proceduralmap.4500.1337.289.sav from proceduralmap.4500.1337.289.sav.new" "${out}"
check "no .sav.new is left" "1" "$(status test -e "${w}/proceduralmap.4500.1337.289.sav.new")"
check "the cut copy is set aside" "cut" "$(cat "${w}"/broken-proceduralmap.4500.1337.289.sav.*)"
rm -f "${w}"/broken-*
# Cut while writing .sav.new: .sav is the previous save and stays.
printf 'half' >"${w}/proceduralmap.4500.1337.289.sav.new"
touch -d '2026-10-17 15:55:46' "${w}/proceduralmap.4500.1337.289.sav.new"
flux_recover_interrupted_saves "${w}" >/dev/null
check "a .sav.new cut while being written leaves .sav alone" "whole" "$(cat "${w}/proceduralmap.4500.1337.289.sav")"
check "and is set aside" "half" "$(cat "${w}"/broken-proceduralmap.4500.1337.289.sav.*)"
rm -f "${w}"/broken-*
# No .sav at all: the .sav.new is all there is.
rm -f "${w}"/*.sav
printf 'only' >"${w}/proceduralmap.4500.1337.289.sav.new"
flux_recover_interrupted_saves "${w}" >/dev/null
check "a lone .sav.new becomes the .sav" "only" "$(cat "${w}/proceduralmap.4500.1337.289.sav")"
check "a normal folder is left alone" "" "$(flux_recover_interrupted_saves "${w}")"

# --- flux-steam.py -------------------------------------------------------------------------------
app_info='Redirecting stderr to /root/.steam/logs/stderr.txt
Logging in user ... OK
AppID : 258550, change number : 1/1, last change : Thu Oct 22 17:30:23 2026
"258550"
{
	"common"
	{
		"name"		"Rust Dedicated Server"
	}
	"depots"
	{
		"258552"
		{
			"manifests" { "public" { "gid" "1" } }
		}
		"branches"
		{
			"public"
			{
				"buildid"		"26139947"
				"timeupdated"		"1792690223"
			}
			"staging"
			{
				"buildid"		"26150000"
				"description"		"a \"quoted\" note"
			}
		}
	}
}
Unloading Steam API...OK'
check "public build from app_info_print" "26139947" "$(python3 scripts/flux-steam.py parse 258550 public <<<"${app_info}")"
check "a beta branch" "26150000" "$(python3 scripts/flux-steam.py parse 258550 staging <<<"${app_info}")"
check "an unknown branch fails" "1" "$(python3 scripts/flux-steam.py parse 258550 nope <<<"${app_info}" >/dev/null 2>&1; echo $?)"
check "another app fails" "1" "$(python3 scripts/flux-steam.py parse 4020 public <<<"${app_info}" >/dev/null 2>&1; echo $?)"
check "an empty answer fails" "1" "$(python3 scripts/flux-steam.py parse 258550 public </dev/null >/dev/null 2>&1; echo $?)"

# --- flux-rcon.py --------------------------------------------------------------------------------
check "flux-rcon without a command is a usage error" "2" "$(python3 scripts/flux-rcon.py >/dev/null 2>&1; echo $?)"
check "flux-rcon without a password fails" "1" "$(FLUX_RCON_ENV=/nonexistent RCON_PASSWORD='' python3 scripts/flux-rcon.py status >/dev/null 2>&1; echo $?)"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
