#!/usr/bin/env bash
#
# Paster 编译校验脚本
#
# 优先使用 xcodebuild 进行完整构建；若当前机器的 Xcode 命令行工具异常
# （例如插件 / 私有框架损坏），自动回退到带 SwiftData 宏插件的
# `swiftc -typecheck`，对全部源码做完整类型检查（含宏展开）。
#
# 用法: bash scripts/build_check.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SCHEME="Paster"
CONFIG="Debug"

echo "==> 尝试使用 xcodebuild 构建 ..."
XCB_OUT=$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" build 2>&1)
XCB_CODE=$?

if echo "$XCB_OUT" | grep -q "BUILD SUCCEEDED"; then
    echo "$XCB_OUT" | tail -5
    echo "==> xcodebuild 构建成功 ✅"
    exit 0
fi

if echo "$XCB_OUT" | grep -q "failed to load a required plug-in"; then
    echo "!! 检测到本机 Xcode 插件 / 框架损坏，xcodebuild 无法启动。"
    echo "!! 回退到 swiftc -typecheck 进行类型检查校验。"
elif [ $XCB_CODE -ne 0 ]; then
    echo "$XCB_OUT" | grep -E "error:" | head -40
    echo "==> xcodebuild 构建失败 ❌"
    exit 1
fi

echo
echo "==> 使用 swiftc -typecheck 校验全部源码（含 SwiftData 宏展开）..."
SDK="$(xcrun --show-sdk-path --sdk macosx)"
PLUGIN="$(xcrun --show-sdk-platform-path)/Developer/usr/lib/swift/host/plugins"

# 收集全部 Swift 源文件
SOURCES=$(find Paster -name '*.swift' | sort)

xcrun swiftc \
    -sdk "$SDK" \
    -target arm64-apple-macosx14.0 \
    -plugin-path "$PLUGIN" \
    -typecheck \
    $SOURCES
CODE=$?

if [ $CODE -eq 0 ]; then
    echo "==> swiftc 类型检查通过 ✅（全部源码语法 / 类型正确）"
else
    echo "==> swiftc 类型检查失败 ❌"
fi
exit $CODE
