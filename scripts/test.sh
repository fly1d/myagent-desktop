#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cargo test --manifest-path "$PROJECT_DIR/backend/Cargo.toml" --locked
cargo build --manifest-path "$PROJECT_DIR/backend/Cargo.toml" --locked
DEVELOPER_ROOT="$(xcode-select -p)"
TEST_FRAMEWORKS="$DEVELOPER_ROOT/Library/Developer/Frameworks"
TEST_LIBRARIES="$DEVELOPER_ROOT/Library/Developer/usr/lib"
# Apple's standalone CLT ships Testing outside SwiftPM's default search path.
# Full Xcode toolchains configure their own framework/runtime paths.
if [[ "$DEVELOPER_ROOT" == */CommandLineTools && -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
  exec swift test --package-path "$PROJECT_DIR" --disable-xctest \
    -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$TEST_LIBRARIES" "$@"
else
  exec swift test --package-path "$PROJECT_DIR" --disable-xctest "$@"
fi
