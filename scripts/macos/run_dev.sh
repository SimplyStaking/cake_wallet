#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR="$SCRIPT_DIR/../.."
DERIVED_DATA_DIR="$ROOT_DIR/build/macos-dev"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Debug/Cake Wallet.app"
DEV_PROFILE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cake-wallet-dev.XXXXXX")
DEV_BUNDLE_ID="com.cakewallet.local.run$(date +%s).$$"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Cake Wallet"

cd "$ROOT_DIR"
CAKE_MACOS_SKIP_NATIVE=1 "$SCRIPT_DIR/build_all.sh"
flutter build macos --debug --config-only >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID" macos/Runner/Info.plist
/usr/bin/sed -i '' \
    "s/^PRODUCT_BUNDLE_IDENTIFIER = .*$/PRODUCT_BUNDLE_IDENTIFIER = $DEV_BUNDLE_ID/" \
    macos/Runner/Configs/AppInfo.xcconfig
pod install --project-directory=macos >/dev/null

xcodebuild \
    -workspace macos/Runner.xcworkspace \
    -scheme Runner \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build \
    CODE_SIGN_ENTITLEMENTS="$SCRIPT_DIR/Dev.entitlements" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Automatic \
    PROVISIONING_PROFILE_SPECIFIER="" \
    DEVELOPMENT_TEAM=""

mkdir -p "$DEV_PROFILE_DIR/Library/Preferences" "$DEV_PROFILE_DIR/Documents"
echo "Using temporary development profile: $DEV_PROFILE_DIR"
echo "Using temporary bundle identifier: $DEV_BUNDLE_ID"

CAKE_WALLET_DIR="$DEV_PROFILE_DIR/Documents" \
CFFIXED_USER_HOME="$DEV_PROFILE_DIR" \
HOME="$DEV_PROFILE_DIR" \
"$APP_EXECUTABLE"
