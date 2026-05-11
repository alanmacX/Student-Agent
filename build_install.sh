#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="ChatBot"
BUILD_DIR="$PROJECT_DIR/.build_output"

echo "⏹  Stopping running app..."
pkill -x "ChatBot" 2>/dev/null || true
sleep 0.5

echo "🔨 Building..."
xcodebuild \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath ./.derivedData \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$BUILD_DIR" \
  build

APP="$BUILD_DIR/Debug/ChatBot.app"

echo "📦 Installing to /Applications..."
cp -R "$APP" /Applications/

echo "🚀 Launching..."
open /Applications/ChatBot.app

echo "✅ Done"
