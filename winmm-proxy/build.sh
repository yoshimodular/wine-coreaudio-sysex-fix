#!/bin/sh
# Builds and installs the winmm proxy that chunks long SysEx messages.
#
#   ./build.sh "My Bottle"      -> installs into that CrossOver bottle
#
# The bug it works around is in Wine, not in any particular program:
# dlls/winecoreaudio.drv/coremidi.c, function midi_send, builds the CoreMIDI
# packet list in a fixed 512-byte buffer and makes a single call to
# MIDIPacketListAdd. If the SysEx is longer than 498 bytes, that function
# returns NULL, Wine skips the MIDISend and sends nothing -- but marks the
# header as done and returns MMSYSERR_NOERROR. The program believes it sent it.
#
# Requires: brew install mingw-w64
#
# This script targets CrossOver. For a plain Wine install, see the "Plain Wine"
# section of the README: the steps are the same, only the paths differ.
set -e

BOTTLE="$1"
[ -n "$BOTTLE" ] || { echo "usage: $0 \"CrossOver bottle name\""; \
                      ls "$HOME/Library/Application Support/CrossOver/Bottles/" 2>/dev/null; exit 1; }
D="$(cd "$(dirname "$0")" && pwd)"
B="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
CX="${CROSSOVER:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"

# Only this bottle's wineserver. `pkill -f wineserver` takes down every other
# CrossOver application that happens to be open, without warning.
# The `return 0` is not decoration: under `set -e` a final non-matching grep
# would abort the script just before the closing instructions.
kill_bottle_wineserver() {
    for w in $(pgrep -x wineserver 2>/dev/null); do
        lsof -p "$w" 2>/dev/null | grep -qF "Bottles/$BOTTLE/" && kill "$w" 2>/dev/null
    done
    return 0
}

[ -d "$B" ] || { echo "Bottle \"$BOTTLE\" does not exist."; \
                 ls "$HOME/Library/Application Support/CrossOver/Bottles/"; exit 1; }

command -v i686-w64-mingw32-gcc >/dev/null || \
    { echo "Missing compiler: brew install mingw-w64"; exit 1; }

# The forwarding table is generated from the real binary, so that it matches
# exactly the winmm of this version of CrossOver.
echo "Generating the forwarding table..."
i686-w64-mingw32-objdump -p "$CX/lib/wine/i386-windows/winmm.dll" \
    | grep -E '\+base\[' | grep -v "Export RVA" > "$D/.exports.raw"
python3 - "$D" <<'EOF'
import re, sys
d = sys.argv[1]
ours = {"midiOutOpen", "midiOutClose", "midiOutLongMsg"}
out = []
for l in open(d + "/.exports.raw"):
    m = re.search(r"\+base\[\s*(\d+)\]\s+\S+\s+(\S+)\s*$", l)
    if m:
        out.append((int(m.group(1)), m.group(2)))
with open(d + "/winmm.def", "w") as f:
    f.write("LIBRARY winmm.dll\nEXPORTS\n")
    for ordn, name in out:
        if name in ours:
            f.write("    %s @%d\n" % (name, ordn))
        else:
            f.write("    %s = wmmreal.%s @%d\n" % (name, name, ordn))
print("  %d exports, %d intercepted" % (len(out), len(ours)))
EOF
rm -f "$D/.exports.raw"

echo "Compiling..."
i686-w64-mingw32-gcc -O2 -shared -o "$D/winmm.dll" "$D/winmmproxy.c" "$D/winmm.def" \
    -lkernel32 -static-libgcc -Wl,--enable-stdcall-fixup
i686-w64-mingw32-gcc -O2 -o "$D/wmiditest.exe" "$D/wmiditest.c" -lwinmm

echo "Installing into \"$BOTTLE\"..."
mkdir -p "$B/drive_c/windows/syswow64"
# wmmreal.dll is the real winmm, and doubles as the backup copy
cp "$CX/lib/wine/i386-windows/winmm.dll" "$B/drive_c/windows/syswow64/wmmreal.dll"
cp "$D/winmm.dll"                        "$B/drive_c/windows/syswow64/winmm.dll"
cp "$D/wmiditest.exe"                    "$B/drive_c/"

# native,builtin and NEVER a bare native: without the fallback, any process
# that does not find the native DLL ends up with no winmm at all.
"$CX/bin/wine" --bottle "$BOTTLE" --wl-app reg add \
    'HKCU\Software\Wine\DllOverrides' /v winmm /t REG_SZ /d 'native,builtin' /f >/dev/null 2>&1
sleep 2; kill_bottle_wineserver; sleep 2

echo "Done. Restart the programs in \"$BOTTLE\"."
echo "Check with:  C:\\wmiditest.exe            (lists the ports)"
echo "             C:\\wmiditest.exe \"PORT\" 15549"
