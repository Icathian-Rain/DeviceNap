#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -eq 0 ]]; then
    architectures=("$(uname -m)")
elif [[ $# -eq 1 && "$1" == --universal ]]; then
    architectures=(arm64 x86_64)
else
    echo "Usage: $0 [--universal]" >&2
    exit 64
fi
mkdir -p build
staging="$(mktemp -d "$PWD/build/.staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/DeviceNap.app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
/usr/bin/ditto Resources "$app/Contents/Resources"
binaries=()
for architecture in "${architectures[@]}"; do
    binary="$staging/DeviceNap-$architecture"
    /usr/bin/swiftc -swift-version 5 -O -target "$architecture-apple-macos13.0" \
        Sources/*.swift -o "$binary"
    binaries+=("$binary")
done
if [[ ${#binaries[@]} -eq 1 ]]; then
    mv "${binaries[0]}" "$app/Contents/MacOS/DeviceNap"
else
    /usr/bin/lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/DeviceNap"
fi
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/ditto "$app" build/DeviceNap.app
echo "$PWD/build/DeviceNap.app"
