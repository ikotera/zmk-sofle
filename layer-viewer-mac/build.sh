#!/bin/sh
# Layer Viewer.app をビルドする。./build.sh install で ~/Applications へコピーする。
set -e
cd "$(dirname "$0")"
APP="build/Layer Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 Sources/*.swift \
  -o "$APP/Contents/MacOS/LayerViewer"
codesign --force -s - "$APP"
echo "built: $APP"
if [ "$1" = "install" ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Layer Viewer.app"
  cp -R "$APP" ~/Applications/
  echo "installed: ~/Applications/Layer Viewer.app"
fi
