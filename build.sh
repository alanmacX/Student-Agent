#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build}"
APP_NAME="ChatBot"
SCHEME="ChatBot"
CONFIGURATION="${CONFIGURATION:-Release}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP_ENTITLEMENTS="$PROJECT_DIR/ChatBot/ChatBot.entitlements"
PRODUCTS_DIR="$BUILD_DIR/Build/Products/$CONFIGURATION"
APP_PATH="$PRODUCTS_DIR/$APP_NAME.app"
INSTALLED_APP_PATH="$INSTALL_DIR/$APP_NAME.app"
SIGN_MODE="${SIGN_MODE:-auto}"
OPEN_AFTER_INSTALL="${OPEN_AFTER_INSTALL:-1}"

fail() {
    echo "✗ $*" >&2
    exit 1
}

detect_development_team() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"Apple Development: .* (\([A-Z0-9][A-Z0-9]*\))".*/\1/p' \
        | head -n 1
}

signing_mode() {
    if [ "$SIGN_MODE" = "development" ] || [ -n "${DEVELOPMENT_TEAM:-}" ]; then
        echo "development"
        return
    fi
    if [ "$SIGN_MODE" = "adhoc" ]; then
        echo "adhoc"
        return
    fi
    if [ -n "$(detect_development_team)" ]; then
        echo "development"
    else
        echo "adhoc"
    fi
}

run_xcodebuild_development() {
    local team="${DEVELOPMENT_TEAM:-$(detect_development_team)}"
    [ -n "$team" ] || fail "没有找到 Apple Development 签名身份。请先在 Xcode 登录开发者账号，或用 SIGN_MODE=adhoc 做本机调试构建。"

    echo "==> 使用 Apple Development 签名编译 $APP_NAME (Team: $team) ..."
    xcodebuild \
        -quiet \
        -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$BUILD_DIR" \
        -destination "platform=macOS" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$team" \
        CODE_SIGN_STYLE=Automatic \
        CODE_SIGNING_ALLOWED=YES \
        build
}

sign_nested_code_adhoc() {
    local bundle_path="$1"

    if [ -d "$bundle_path/Contents/Frameworks" ]; then
        while IFS= read -r -d '' framework; do
            codesign --force --sign - --timestamp=none "$framework"
        done < <(find "$bundle_path/Contents/Frameworks" -type d -name "*.framework" -print0)

        while IFS= read -r -d '' dylib; do
            codesign --force --sign - --timestamp=none "$dylib"
        done < <(find "$bundle_path/Contents/Frameworks" -type f -name "*.dylib" -print0)
    fi
}

run_xcodebuild_adhoc() {
    echo "==> 使用本机 ad-hoc 签名编译 $APP_NAME ..."
    xcodebuild \
        -quiet \
        -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$BUILD_DIR" \
        -destination "platform=macOS" \
        CODE_SIGNING_ALLOWED=NO \
        ENABLE_HARDENED_RUNTIME=NO \
        build

    echo "==> 对主 app 做 ad-hoc 签名 ..."
    sign_nested_code_adhoc "$APP_PATH"
    codesign --force --sign - --timestamp=none --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"
}

mkdir -p "$BUILD_DIR"

MODE="$(signing_mode)"
if [ "$MODE" = "development" ]; then
    if run_xcodebuild_development; then
        :
    else
        echo "⚠ Apple Development 签名失败（账号未登录或无 provisioning profile），改用 ad-hoc 签名 ..."
        run_xcodebuild_adhoc
    fi
else
    run_xcodebuild_adhoc
fi

[ -d "$APP_PATH" ] || fail "编译失败，找不到 .app 文件：$APP_PATH"

echo "==> 安装到 $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
if [ -d "$INSTALLED_APP_PATH" ]; then
    rm -rf "$INSTALLED_APP_PATH"
fi
ditto "$APP_PATH" "$INSTALLED_APP_PATH"

xattr -cr "$INSTALLED_APP_PATH" 2>/dev/null || true

if [ "$OPEN_AFTER_INSTALL" = "1" ]; then
    echo "==> 打开 $APP_NAME ..."
    open "$INSTALLED_APP_PATH" || true
fi

echo ""
echo "✓ 安装完成：$INSTALLED_APP_PATH"
