#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${1:-$REPO_ROOT/.build/antigravity-plugin}"

export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Applications/Xcode.app/Contents/Developer/usr/bin"

echo "Building swift-mcp-server release binary..."
swift build --package-path "$REPO_ROOT" --configuration release --product swift-mcp-server
BIN_DIR="$(swift build --package-path "$REPO_ROOT" --configuration release --show-bin-path)"
BUILT_BIN="$BIN_DIR/swift-mcp-server"

if [ ! -x "$BUILT_BIN" ]; then
  echo "Error: release binary not found at $BUILT_BIN" >&2
  exit 1
fi

echo "Staging Antigravity plugin bundle at $OUTPUT_DIR..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/scripts" "$OUTPUT_DIR/assets" "$OUTPUT_DIR/rules" "$OUTPUT_DIR/skills"

cp "$REPO_ROOT/plugin.json" "$OUTPUT_DIR/plugin.json"
cp "$REPO_ROOT/mcp_config.json" "$OUTPUT_DIR/mcp_config.json"
cp "$REPO_ROOT/README.md" "$OUTPUT_DIR/README.md"
cp "$REPO_ROOT/LICENSE" "$OUTPUT_DIR/LICENSE"
cp -R "$REPO_ROOT/assets/." "$OUTPUT_DIR/assets/"
cp -R "$REPO_ROOT/rules/." "$OUTPUT_DIR/rules/"
cp -R "$REPO_ROOT/skills/." "$OUTPUT_DIR/skills/"
cp "$REPO_ROOT/scripts/run-mcp.sh" "$OUTPUT_DIR/scripts/run-mcp.sh"
cp "$BUILT_BIN" "$OUTPUT_DIR/scripts/swift-mcp-server"

chmod 0755 "$OUTPUT_DIR/scripts/run-mcp.sh" "$OUTPUT_DIR/scripts/swift-mcp-server"

if command -v agy >/dev/null 2>&1; then
  echo "Validating staged Antigravity plugin..."
  agy plugin validate "$OUTPUT_DIR"
fi

echo ""
echo "Staged Antigravity plugin bundle is ready:"
echo "  $OUTPUT_DIR"
echo ""
echo "Install locally with:"
echo "  agy plugin install \"$OUTPUT_DIR\""
