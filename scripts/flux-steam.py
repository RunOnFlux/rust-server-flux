#!/usr/bin/env python3
"""flux-steam: the build id Steam currently lists for a branch of an app.

    flux-steam.py buildid <app> <branch>     prints the build id, exit 1 when it cannot be read
    flux-steam.py parse <app> <branch>       the same, from `app_info_print` output on stdin

Asks SteamCMD (anonymous) with a fresh app info cache: SteamCMD answers `app_info_print` from
its local appinfo.vdf, which can be days old, so the cache file is removed first and
`app_info_update 1` forces the refresh. A third-party API would be quicker and is one more
service that can go away; Steam is the source of truth the update itself uses.
"""
import glob
import os
import re
import subprocess
import sys

TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|([{}])')


def parse_vdf(text):
    """Text VDF -> nested dicts. Unquoted junk around it (SteamCMD's own log lines) is skipped."""
    root = {}
    stack = [root]
    key = None
    for m in TOKEN.finditer(text):
        word, brace = m.group(1), m.group(2)
        if brace == "{":
            child = {}
            if key is not None:
                stack[-1][key] = child
            stack.append(child)
            key = None
        elif brace == "}":
            if len(stack) > 1:
                stack.pop()
            key = None
        elif key is None:
            key = word
        else:
            stack[-1][key] = word
            key = None
    return root


def buildid_from(text, app, branch):
    info = parse_vdf(text).get(str(app))
    if not isinstance(info, dict):
        return None
    branches = (info.get("depots") or {}).get("branches") or {}
    entry = branches.get(branch)
    if isinstance(entry, dict) and re.fullmatch(r"\d+", entry.get("buildid", "")):
        return entry["buildid"]
    return None


def query(app):
    home = os.path.expanduser("~")
    for pattern in ("Steam/appcache/appinfo.vdf", ".local/share/Steam/appcache/appinfo.vdf",
                    ".steam/steam/appcache/appinfo.vdf"):
        for path in glob.glob(os.path.join(home, pattern)):
            try:
                os.remove(path)
            except OSError:
                pass
    out = subprocess.run(
        ["steamcmd", "+login", "anonymous", "+app_info_update", "1", "+app_info_print", str(app), "+quit"],
        capture_output=True, text=True, timeout=int(os.environ.get("FLUX_STEAM_TIMEOUT", "180")),
        check=False,
    )
    return out.stdout


def main(argv):
    if len(argv) != 3 or argv[0] not in ("buildid", "parse"):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    mode, app, branch = argv
    try:
        text = sys.stdin.read() if mode == "parse" else query(app)
    except (OSError, subprocess.SubprocessError) as e:
        print(f"flux-steam: {e}", file=sys.stderr)
        return 1
    build = buildid_from(text, app, branch)
    if not build:
        print(f"flux-steam: no build id for {app} branch {branch}", file=sys.stderr)
        return 1
    print(build)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
