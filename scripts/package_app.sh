#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${VERSION:-1.0.0}"
APP_NAME="CutWord"
BUNDLE_ID="com.wangbuilds.cutword"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}-macos-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
ICON_SRC="${ICON_SRC:-$ROOT_DIR/docs/media/app-icon-1024.png}"

echo "==> [1/5] Building Release binaries (arm64)..."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_BUNDLE" "$DMG_PATH"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_DIR/CutWordApp" "$APP_BUNDLE/Contents/MacOS/CutWordApp"
cp "$BIN_DIR/cutword" "$APP_BUNDLE/Contents/MacOS/cutword"
chmod +x "$APP_BUNDLE/Contents/MacOS/CutWordApp" "$APP_BUNDLE/Contents/MacOS/cutword"

echo "==> [2/5] Building AppIcon.icns..."
if [[ -f "$ICON_SRC" ]]; then
  ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"
  for sz in 16 32 128 256 512; do
    sips -s format png -z "$sz" "$sz" "$ICON_SRC" --out "$ICONSET_DIR/icon_${sz}x${sz}.png" >/dev/null
    sz2=$((sz * 2))
    sips -s format png -z "$sz2" "$sz2" "$ICON_SRC" --out "$ICONSET_DIR/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET_DIR")"
fi

echo "==> [3/5] Writing Info.plist..."
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>CutWord · 剪字</string>
  <key>CFBundleExecutable</key>
  <string>CutWordApp</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>100</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.video</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>CutWord 调用 macOS 本地离线语音引擎提取导入视频的逐字时间戳，音视频全程不离开本机。</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Video Media</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.mpeg-4</string>
        <string>com.apple.quicktime-movie</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF

echo "==> [4/5] Ad-hoc signing ${APP_NAME}.app..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> [5/5] Creating ${DMG_NAME}..."
DMG_STAGE="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGE"

echo ""
echo "✅ Packaged successfully:"
ls -lh "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
