#!/bin/sh
# Builds the CoreMIDI measurement tools and installs them into ~/bin
set -e
cd "$(dirname "$0")"
mkdir -p "$HOME/bin"
for f in sysexsend midisniff midirecv midislow midispeed; do
    printf "%-12s " "$f"
    swiftc -O "$f.swift" -o "$HOME/bin/$f" 2>&1 | grep -E "error" && exit 1
    echo "ok"
done
echo "Installed into ~/bin"
