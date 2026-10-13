#!/bin/sh
# Layer Viewer.app をビルドする。./build.sh install で ~/Applications へ入れ替える。
#   版: VERSION ファイルが唯一の正本（Info.plist の CFBundleShortVersionString へ入れる）
#   署名: Apple Development の証明書があればそれで署名する。署名が毎回同じになるので、
#         入力監視の許可がビルドのたびに外れない。無ければアドホック署名（許可はビルドごとに出し直し）
set -e
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
APP="build/Layer Viewer.app"

swift build -c release --product LayerViewer
BIN=$(swift build -c release --show-bin-path)/LayerViewer

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/LayerViewer"
cp Info.plist "$APP/Contents/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "built: $APP (v$VERSION, 署名: ${IDENTITY:-アドホック})"

if [ "$1" = "install" ]; then
  pkill -x LayerViewer 2>/dev/null && sleep 1 || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Layer Viewer.app"
  cp -R "$APP" ~/Applications/
  echo "installed: ~/Applications/Layer Viewer.app"
fi
