#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/paster-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find Paster -name '*.swift' ! -name PasterApp.swift | sort)
xcrun swiftc -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target "$(uname -m)-apple-macosx14.0" \
  -plugin-path "$(xcrun --show-sdk-platform-path)/Developer/usr/lib/swift/host/plugins" \
  -module-cache-path "$TEST_DIR/modules" -parse-as-library \
  "${SOURCES[@]}" tests/macOSRegression.swift -o "$TEST_DIR/regression"
"$TEST_DIR/regression"
