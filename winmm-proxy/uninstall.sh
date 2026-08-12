#!/bin/sh
# Puts the bottle back the way it was.   ./uninstall.sh ["Bottle name"]
BOTTLE="$1"
[ -n "$BOTTLE" ] || { echo "usage: $0 \"CrossOver bottle name\""; exit 1; }
B="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
CX="${CROSSOVER:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"
[ -f "$B/drive_c/windows/syswow64/wmmreal.dll" ] && \
    cp "$B/drive_c/windows/syswow64/wmmreal.dll" "$B/drive_c/windows/syswow64/winmm.dll"
"$CX/bin/wine" --bottle "$BOTTLE" --wl-app reg delete \
    'HKCU\Software\Wine\DllOverrides' /v winmm /f >/dev/null 2>&1
sleep 2; pkill -f wineserver 2>/dev/null
echo "Proxy removed from \"$BOTTLE\". Restart the programs."
