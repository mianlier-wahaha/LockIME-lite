#!/bin/zsh
# LockIME-lite 构建脚本：纯 clang / swiftc，零 Xcode 工程、零第三方依赖。
# 用法：./build.sh [版本号]     例：./build.sh 1.0.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$BUILD/LockIME-lite.app"
TARGET="arm64-apple-macosx14.0"
VERSION="${1:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo 1.0.0)}"

echo "==> 版本 $VERSION"
echo "==> 清理"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 daemon (Objective-C, ARC)"
clang -O2 -fobjc-arc -fmodules \
    -target "$TARGET" \
    -framework Foundation -framework AppKit -framework Carbon \
    "$ROOT/Sources/Daemon/main.m" \
    -o "$BUILD/lockime-lite-daemon"

echo "==> 编译 GUI (SwiftUI)"
swiftc -O -parse-as-library -disable-sandbox -target "$TARGET" \
    -framework SwiftUI -framework AppKit -framework Carbon \
    "$ROOT/Sources/GUI/LockIMELite.swift" \
    -o "$APP/Contents/MacOS/LockIME-lite"

echo "==> 组装 App Bundle"
cp "$ROOT/Sources/GUI/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/lockime-lite-daemon" "$APP/Contents/Resources/lockime-lite-daemon"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/com.lockime-lite.daemon.plist" "$APP/Contents/Resources/com.lockime-lite.daemon.plist"
cp "$ROOT/README.md" "$ROOT/ATTRIBUTION.md" "$ROOT/LICENSE" "$APP/Contents/Resources/" 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion ${2:-1}" "$APP/Contents/Info.plist"

echo "==> ad-hoc 签名"
codesign --force --sign - "$BUILD/lockime-lite-daemon"
codesign --force --deep --sign - "$APP"

echo "==> 打包 dmg"
rm -rf "$DIST" && mkdir -p "$DIST/stage"
cp -R "$APP" "$DIST/stage/"
ln -sf /Applications "$DIST/stage/Applications"
hdiutil create -quiet -volname "LockIME-lite $VERSION" \
    -srcfolder "$DIST/stage" -ov -format UDZO \
    "$DIST/LockIME-lite-$VERSION.dmg"
rm -rf "$DIST/stage"

echo ""
echo "完成 ($VERSION)"
echo "  App: $APP"
echo "  dmg: $DIST/LockIME-lite-$VERSION.dmg  ($(du -h "$DIST/LockIME-lite-$VERSION.dmg" | cut -f1))"
echo "运行：open \"$APP\""
