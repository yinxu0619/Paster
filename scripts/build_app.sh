#!/usr/bin/env bash
#
# Paster 手动打包脚本
#
# 由于本机 xcodebuild 的模拟器插件 / 私有框架损坏无法启动，这里直接用
# swiftc 编译全部源码，并手工组装出可运行的 Paster.app（ad-hoc 签名）。
#
# 产物：build/Paster.app 与 build/Paster.zip
#
# 用法: bash scripts/build_app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Paster"
BUNDLE_ID="com.paster.Paster"
VERSION="1.1"
BUILD_NUMBER="2"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

SDK="$(xcrun --show-sdk-path --sdk macosx)"
PLUGIN="$(xcrun --show-sdk-platform-path)/Developer/usr/lib/swift/host/plugins"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"

echo "==> 清理旧产物"
rm -rf "$APP" "$BUILD_DIR/$APP_NAME.zip"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> 编译 Swift 源码 (target=$TARGET)"
SOURCES=$(find Paster -name '*.swift' | sort)
xcrun swiftc \
    -sdk "$SDK" \
    -target "$TARGET" \
    -plugin-path "$PLUGIN" \
    -parse-as-library \
    -swift-version 5 \
    -o "$MACOS_DIR/$APP_NAME" \
    $SOURCES

echo "==> 拷贝应用图标 (.icns)"
ICON_SRC="Paster/Resources/Paster.icns"
ICON_NAME=""
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$RES_DIR/Paster.icns"
    ICON_NAME="Paster"
    echo "   已嵌入 $RES_DIR/Paster.icns"
else
    echo "   未找到 $ICON_SRC，跳过图标（可运行 scripts 生成图标后重试）"
fi

echo "==> 拷贝赞赏码等捆绑资源"
shopt -s nullglob
DONATE_PNGS=(Paster/Resources/Donate/*.png)
if [ ${#DONATE_PNGS[@]} -gt 0 ]; then
    cp "${DONATE_PNGS[@]}" "$RES_DIR/"
    echo "   已嵌入 ${#DONATE_PNGS[@]} 张赞赏码：$(ls "$RES_DIR"/donate_*.png 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
else
    echo "   未找到赞赏码图片（Paster/Resources/Donate/*.png）"
fi
shopt -u nullglob

echo "==> 拷贝本地化资源"
for lproj in Paster/Resources/*.lproj; do
    if [ -d "$lproj" ]; then
        cp -R "$lproj" "$RES_DIR/"
        echo "   已嵌入 $(basename "$lproj")"
    fi
done

echo "==> 生成 Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>$ICON_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Paster</string>
</dict>
</plist>
PLIST

echo "==> 写入 PkgInfo"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Ad-hoc 代码签名"
codesign --force --deep --sign - \
    --entitlements Paster/Resources/Paster.entitlements \
    "$APP" 2>/dev/null \
    || codesign --force --deep --sign - "$APP"

echo "==> 校验签名"
codesign --verify --verbose=2 "$APP" || true

echo "==> 刷新图标缓存 / 重新注册 LaunchServices"
APP_ABS="$(cd "$BUILD_DIR" && pwd)/$APP_NAME.app"
touch "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP_ABS" >/dev/null 2>&1 \
        && echo "   已重新注册（图标若未刷新可执行: killall Finder Dock）" \
        || echo "   lsregister 受限跳过（手动: touch 应用后 killall Finder Dock）"
fi

echo "==> 打包 zip"
( cd "$BUILD_DIR" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip" )

echo
echo "==> 完成 ✅"
echo "    应用: $APP"
echo "    压缩: $BUILD_DIR/$APP_NAME.zip"
echo "    可执行: $MACOS_DIR/$APP_NAME"
