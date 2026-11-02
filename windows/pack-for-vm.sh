#!/bin/bash
# Build on the Mac and upload a zip of the Windows binaries and probe scripts,
# for a test VM to download. Prints the download URL.
#   windows/pack-for-vm.sh
set -euo pipefail
cd "$(dirname "$0")"
./build-from-mac.sh >/dev/null
OUT="$(mktemp -d)/bcu"
mkdir -p "$OUT"
cp target/x86_64-pc-windows-msvc/release/{bcu-probe,bcu,BackgroundComputerUse}.exe "$OUT/"
cp probe/phase0/* "$OUT/"
cp app/install-monitor.ps1 "$OUT/"
mkdir -p "$OUT/skills"
cp -R ../skills/background-computer-use "$OUT/skills/"
(cd "$(dirname "$OUT")" && zip -qr bcu-windows.zip bcu)
id="$(fs up "$(dirname "$OUT")/bcu-windows.zip" --tag bcu-windows-dev --id)"
echo "https://files.moulik.dev/raw/$id"
