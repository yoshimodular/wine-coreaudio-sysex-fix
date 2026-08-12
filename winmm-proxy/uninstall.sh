#!/bin/sh
# Puts the bottle back the way it was.   ./uninstall.sh ["Bottle name"]
BOTTLE="$1"
[ -n "$BOTTLE" ] || { echo "usage: $0 \"CrossOver bottle name\""; exit 1; }
B="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
CX="${CROSSOVER:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"

# Only this bottle's wineserver. `pkill -f wineserver` takes down every other
# CrossOver application that happens to be open, without warning.
kill_bottle_wineserver() {
    for w in $(pgrep -x wineserver 2>/dev/null); do
        lsof -p "$w" 2>/dev/null | grep -qF "Bottles/$BOTTLE/" && kill "$w" 2>/dev/null
    done
    # The `return 0` keeps the function from returning 1 when the last
    # wineserver examined is not this bottle's, which is the normal case.
    # There is no `set -e` here (there is in build.sh, where that did abort the
    # script), but a misleading exit status is no use to anyone.
    return 0
}

[ -f "$B/drive_c/windows/syswow64/wmmreal.dll" ] && \
    cp "$B/drive_c/windows/syswow64/wmmreal.dll" "$B/drive_c/windows/syswow64/winmm.dll"
"$CX/bin/wine" --bottle "$BOTTLE" --wl-app reg delete \
    'HKCU\Software\Wine\DllOverrides' /v winmm /f >/dev/null 2>&1
sleep 2; kill_bottle_wineserver
echo "Proxy removed from \"$BOTTLE\". Restart the programs."
