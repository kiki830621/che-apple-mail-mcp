#!/bin/bash
# Deploy updated binary and restart MCP server
# Usage: ./scripts/deploy.sh

set -e

cd "$(dirname "$0")/.."
BINARY_NAME="CheAppleMailMCP"
TARGET_DIR="$HOME/bin"

echo "Building release..."
swift build -c release

echo "Deploying to $TARGET_DIR..."
cp ".build/release/$BINARY_NAME" "$TARGET_DIR/$BINARY_NAME"

echo "Restarting MCP server..."
pkill -f "$BINARY_NAME" 2>/dev/null || true

echo "✅ Done! MCP server will auto-reconnect."
