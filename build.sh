#!/bin/zsh
# PopNote!.appをこのフォルダ直下に作る。Xcode Command Line Tools（swiftc）が必要。
# macOS 13以降：同梱のSQLiteがTomeletのDB（STRICT表）に対応している必要がある。
set -euo pipefail
cd "${0:A:h}"

APP_NAME="PopNote!"
VERSION="0.2.0"
BUILD_DIR=".build"
STAGE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$STAGE/Contents"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$BUILD_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp -R web "$CONTENTS/Resources/web"
# 画面左上のアイコン（アプリのアイコンと同じ絵）。
cp assets/icon/icon.svg "$CONTENTS/Resources/web/icon.svg"
# Tomeletと同じDB更新。保存先に新しいデータを作るときに使う（scripts/sync-schema.shで更新）。
cp -R schema "$CONTENTS/Resources/schema"
cp assets/icon/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>ja</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleExecutable</key><string>PopNote</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>io.github.kobito-tools.popnote</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>io.github.kobito-tools.popnote</string>
  <key>CFBundleURLSchemes</key><array><string>popnote</string></array>
</dict></array>
</dict></plist>
PLIST

# Apple Silicon・Intelの両方で動くユニバーサルバイナリにする。
for arch in arm64 x86_64; do
  xcrun swiftc -sdk "$SDK" -target "$arch-apple-macosx13.0" -parse-as-library -O \
    Sources/*.swift -framework Cocoa -framework WebKit -lsqlite3 -o "$BUILD_DIR/PopNote-$arch"
done
lipo -create "$BUILD_DIR/PopNote-arm64" "$BUILD_DIR/PopNote-x86_64" -output "$CONTENTS/MacOS/PopNote"
codesign --force --sign - --timestamp=none "$STAGE"

rm -rf "$APP_NAME.app"
mv "$STAGE" "$APP_NAME.app"
rm -rf "$BUILD_DIR"

# popnote:// をすぐ使えるように Launch Services へ登録する。
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$PWD/$APP_NAME.app"
echo "$PWD/$APP_NAME.app"
