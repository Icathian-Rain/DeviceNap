#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
staging="$(mktemp -d "$PWD/build/.staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/DeviceNap.app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
/usr/bin/ditto Resources "$app/Contents/Resources"
/usr/bin/swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos13.0" \
    Sources/*.swift -o "$app/Contents/MacOS/DeviceNap"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/ditto "$app" build/DeviceNap.app
echo "$PWD/build/DeviceNap.app"
