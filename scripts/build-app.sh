#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "MyAgent.app 需要在 macOS 上构建。" >&2
  exit 1
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "请安装 Rust 工具链（cargo），用于构建独立后端。" >&2
  exit 1
fi
cargo build --manifest-path "$PROJECT_DIR/backend/Cargo.toml" --release --locked
APP_VERSION="$(cargo metadata --manifest-path "$PROJECT_DIR/backend/Cargo.toml" --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["packages"][0]["version"])')"

swift build --package-path "$PROJECT_DIR" --configuration release
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --configuration release --show-bin-path)"
mkdir -p "$PROJECT_DIR/dist"
STAGE_DIR="$(mktemp -d "$PROJECT_DIR/dist/.MyAgent.XXXXXX")"
trap 'rm -rf -- "$STAGE_DIR"' EXIT
APP_DIR="$STAGE_DIR/MyAgent.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/backend" "$APP_DIR/Contents/Resources/licenses"
cp "$BIN_DIR/MyAgent" "$APP_DIR/Contents/MacOS/MyAgent"
cp "$PROJECT_DIR/backend/target/release/myagent-backend" "$APP_DIR/Contents/Resources/backend/"
cp "$PROJECT_DIR/LICENSE" "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/licenses/"
python3 "$SCRIPT_DIR/collect-licenses.py" "$APP_DIR/Contents/Resources/licenses/rust"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.myagent.desktop</string>
  <key>CFBundleExecutable</key><string>MyAgent</string>
  <key>CFBundleName</key><string>MyAgent</string>
  <key>CFBundleDisplayName</key><string>MyAgent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>在你授权后，MyAgent 可以操作你选择的浏览器或应用来完成任务。</string>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"

/usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR/Contents/Resources/backend/myagent-backend"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

rm -rf -- "$PROJECT_DIR/dist/MyAgent.app"
mv "$APP_DIR" "$PROJECT_DIR/dist/MyAgent.app"
printf '已构建：%s\n' "$PROJECT_DIR/dist/MyAgent.app"
