#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
out="$repo/macos/build"
mkdir -p "$out"
stage=$(mktemp -d "$out/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/volume/OpenMission.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/searxng"
res="$app/Contents/Resources"
cp compose.yaml NOTICE LICENSE "$res/"
cp .env.example "$res/release.env"
cp searxng/settings.yml "$res/searxng/"
cp macos/Info.plist "$app/Contents/"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -O \
  -module-cache-path "$out/module-cache" macos/Sources/*.swift -o "$app/Contents/MacOS/OpenMission"
# ICNS supports a 512px PNG payload in an ic09 element.
python3 - "$repo/assets/sg_github_kawaii.png" "$res/OpenMission.icns" <<'PY'
import pathlib, struct, sys
png = pathlib.Path(sys.argv[1]).read_bytes()
icon = b"ic09" + struct.pack(">I", len(png) + 8) + png
pathlib.Path(sys.argv[2]).write_bytes(b"icns" + struct.pack(">I", len(icon) + 8) + icon)
PY
codesign --force --sign - "$app"
codesign --verify --strict --verbose=1 "$app"
ln -s /Applications "$stage/volume/Applications"
hdiutil create -quiet -fs HFS+ -format UDZO -volname OpenMission -srcfolder "$stage/volume" "$stage/OpenMission.dmg"
hdiutil verify -quiet "$stage/OpenMission.dmg"
mv "$stage/OpenMission.dmg" "$out/OpenMission.dmg"
echo "Built $out/OpenMission.dmg"
