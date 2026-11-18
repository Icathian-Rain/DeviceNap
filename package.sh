#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --universal
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw Info.plist)"
image="$PWD/build/DeviceNap-$version-universal.dmg"
staging="$(mktemp -d "$PWD/build/.package.XXXXXX")"
trap '/bin/rm -rf "$staging"' EXIT
mkdir "$staging/volume"

/usr/bin/ditto build/DeviceNap.app "$staging/volume/DeviceNap.app"
ln -s /Applications "$staging/volume/Applications"
/usr/bin/hdiutil create -quiet -volname DeviceNap -srcfolder "$staging/volume" \
    -fs HFS+ -format UDZO "$staging/DeviceNap.dmg"
/usr/bin/hdiutil verify -quiet "$staging/DeviceNap.dmg"
mv -f "$staging/DeviceNap.dmg" "$image"
echo "$image"
