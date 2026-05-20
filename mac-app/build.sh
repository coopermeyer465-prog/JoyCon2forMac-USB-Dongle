#!/bin/bash

set -euo pipefail

echo "Building JoyCon2forMac Utility..."

cd "$(dirname "$0")"

APP_NAME="JoyCon2forMac"
APP_EXECUTABLE="JoyCon2forMac"
BUILD_DIR="${BUILD_DIR:-build.noindex}"
DIST_DIR="${DIST_DIR:-dist.noindex}"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
APP_INFO_PLIST="Joycon2forMac-App-Info.plist"
APP_ENTITLEMENTS="Joycon2forMac.entitlements"
CONFIG_FILE="joycon2_config.json"
APP_ICON_FILE="assets/JoyCon2forMac.icns"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
RELEASE_DRAFT="${RELEASE_DRAFT:-false}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"

mkdir -p "$BUILD_DIR"

BUILD_MODE=${1:-FULL}
BUILD_TYPE=${2:-debug}

if [ "$BUILD_TYPE" = "debug" ]; then
    DEBUG_FLAG="-DDEBUG"
else
    DEBUG_FLAG=""
fi

bundle_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_INFO_PLIST" 2>/dev/null || echo "1.0"
}

repo_slug() {
    local remote_url
    remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
    if [[ -z "$remote_url" ]]; then
        return 1
    fi

    remote_url="${remote_url%.git}"
    remote_url="${remote_url#git@github.com:}"
    remote_url="${remote_url#https://github.com/}"
    remote_url="${remote_url#http://github.com/}"
    echo "$remote_url"
}

sign_app_bundle() {
    local bundle_path="$1"

    if ! command -v codesign >/dev/null 2>&1; then
        echo "codesign not found; leaving app unsigned."
        return
    fi

    xattr -cr "$bundle_path"

    if [ -f "$APP_ENTITLEMENTS" ]; then
        codesign --force --deep --sign "$CODESIGN_IDENTITY" --entitlements "$APP_ENTITLEMENTS" "$bundle_path"
    else
        codesign --force --deep --sign "$CODESIGN_IDENTITY" "$bundle_path"
    fi

    codesign --verify --deep --strict --verbose=0 "$bundle_path"
}

build_full_binary() {
    echo "Building in FULL mode (Joycon2VirtualHID with BLE and HID emulation) in $BUILD_TYPE mode..."
    clang++ -std=c++17 -x objective-c++ $DEBUG_FLAG \
        -framework Foundation -framework AppKit -framework IOKit -framework CoreBluetooth -framework ApplicationServices \
        -Iinclude src/Joycon2VirtualHID.mm src/Joycon2BLEReceiver.mm src/main_ble.mm \
        -o "${BUILD_DIR}/Joycon2VirtualHID"
}

assemble_signed_app_bundle() {
    local target_bundle="$1"

    mkdir -p "$target_bundle/Contents/MacOS"
    mkdir -p "$target_bundle/Contents/Resources"
    clang++ -std=c++17 -x objective-c++ $DEBUG_FLAG \
        -framework Foundation -framework AppKit -framework IOKit -framework CoreBluetooth -framework ApplicationServices -framework ServiceManagement \
        -Iinclude src/Joycon2App.mm src/Joycon2VirtualHID.mm src/Joycon2BLEReceiver.mm \
        -o "$target_bundle/Contents/MacOS/$APP_EXECUTABLE"

    cp "$APP_INFO_PLIST" "$target_bundle/Contents/Info.plist"
    cp "$CONFIG_FILE" "$target_bundle/Contents/Resources/$CONFIG_FILE"
    if [ -f "$APP_ICON_FILE" ]; then
        cp "$APP_ICON_FILE" "$target_bundle/Contents/Resources/JoyCon2forMac.icns"
    fi

    sign_app_bundle "$target_bundle"
}

build_app_bundle() {
    local stage_root
    local stage_bundle

    echo "Building in APP mode (${APP_NAME}.app) in $BUILD_TYPE mode..."
    stage_root="$(mktemp -d /tmp/joycon2formac-build.XXXXXX)"
    stage_bundle="$stage_root/${APP_NAME}.app"

    rm -rf "$APP_BUNDLE"
    assemble_signed_app_bundle "$stage_bundle"
    ditto "$stage_bundle" "$APP_BUNDLE"
    rm -rf "$stage_root"
}

build_ble_only() {
    echo "Building in BLE_ONLY mode (Joycon2BLEReceiver for BLE communication only) in $BUILD_TYPE mode..."
    clang++ -std=c++17 -x objective-c++ $DEBUG_FLAG -DHID_ENABLE \
        -framework Foundation -framework CoreBluetooth \
        -Iinclude src/Joycon2BLEReceiver.mm src/main_ble.mm \
        -o "${BUILD_DIR}/Joycon2BLEReceiver"
}

build_dist() {
    local version
    local package_root
    local package_folder_name
    local zip_path
    local dmg_path
    local stable_zip_path
    local stable_dmg_path
    local dmg_stage
    local stage_root
    local stage_bundle

    version="$(bundle_version)"
    stage_root="$(mktemp -d /tmp/joycon2formac-dist.XXXXXX)"
    stage_bundle="$stage_root/${APP_NAME}.app"

    package_root="$DIST_DIR/${APP_NAME}-${version}"
    package_folder_name="$(basename "$package_root")"
    zip_path="$DIST_DIR/${APP_NAME}-${version}-macOS.zip"
    dmg_path="$DIST_DIR/${APP_NAME}-${version}-macOS.dmg"
    stable_zip_path="$DIST_DIR/${APP_NAME}-macOS.zip"
    stable_dmg_path="$DIST_DIR/${APP_NAME}-macOS.dmg"
    dmg_stage="$DIST_DIR/.dmg-stage"

    echo "Building in DIST mode (${APP_NAME}.app) in $BUILD_TYPE mode..."
    assemble_signed_app_bundle "$stage_bundle"

    rm -rf "$APP_BUNDLE"
    ditto "$stage_bundle" "$APP_BUNDLE"

    echo "Packaging distributable artifacts for version $version..."
    rm -rf "$package_root" "$zip_path" "$dmg_path" "$dmg_stage"
    mkdir -p "$package_root"
    ditto "$stage_bundle" "$package_root/${APP_NAME}.app"

    /usr/bin/touch "$package_root/INSTALL.txt"
    /bin/cat > "$package_root/INSTALL.txt" <<EOF
JoyCon2forMac macOS Install

1. Drag JoyCon2forMac.app into /Applications.
2. Open the app once from /Applications.
3. Grant Bluetooth and Accessibility if macOS prompts.
4. The app can run in the menu bar without its window open.

Notes:
- This build is ad-hoc signed locally for easier distribution.
- For launch-at-login and the smoothest Gatekeeper experience, a Developer ID signed and notarized release is still better.
- Config is stored in:
  ~/Library/Application Support/JoyCon2forMac/joycon2_config.json
EOF

    (
        cd "$DIST_DIR"
        ditto -c -k --keepParent "$package_folder_name" "$(basename "$zip_path")"
    )

    mkdir -p "$dmg_stage"
    ditto "$stage_bundle" "$dmg_stage/${APP_NAME}.app"
    ln -s /Applications "$dmg_stage/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$dmg_stage" -ov -format UDZO "$dmg_path" >/dev/null

    # Stable names for README "latest download" links.
    cp -f "$zip_path" "$stable_zip_path"
    cp -f "$dmg_path" "$stable_dmg_path"

    rm -rf "$dmg_stage" "$stage_root"

    echo "Distributable artifacts created:"
    echo "  $zip_path"
    echo "  $dmg_path"
    echo "  $stable_zip_path"
    echo "  $stable_dmg_path"
    echo "  $package_root/INSTALL.txt"
}

publish_release() {
    local version
    local tag
    local title
    local zip_path
    local dmg_path
    local stable_zip_path
    local stable_dmg_path
    local repo
    local draft_flag=""
    local notes_args=()

    if ! command -v gh >/dev/null 2>&1; then
        echo "gh CLI is required for RELEASE mode."
        exit 1
    fi

    version="$(bundle_version)"
    tag="v${version}"
    title="${APP_NAME} ${version}"
    zip_path="$DIST_DIR/${APP_NAME}-${version}-macOS.zip"
    dmg_path="$DIST_DIR/${APP_NAME}-${version}-macOS.dmg"
    stable_zip_path="$DIST_DIR/${APP_NAME}-macOS.zip"
    stable_dmg_path="$DIST_DIR/${APP_NAME}-macOS.dmg"
    repo="$(repo_slug)"

    build_dist

    if [[ "$RELEASE_DRAFT" == "true" ]]; then
        draft_flag="--draft"
    fi

    if [[ -n "$RELEASE_NOTES_FILE" ]]; then
        notes_args=(--notes-file "$RELEASE_NOTES_FILE")
    else
        notes_args=(--generate-notes)
    fi

    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
        echo "Updating existing GitHub release $tag..."
        gh release upload "$tag" "$zip_path" "$dmg_path" "$stable_zip_path" "$stable_dmg_path" --clobber --repo "$repo"
        if [[ -n "$draft_flag" ]]; then
            gh release edit "$tag" --title "$title" "$draft_flag" --repo "$repo"
        else
            gh release edit "$tag" --title "$title" --repo "$repo"
        fi
    else
        echo "Creating GitHub release $tag..."
        if [[ -n "$draft_flag" ]]; then
            gh release create "$tag" "$zip_path" "$dmg_path" "$stable_zip_path" "$stable_dmg_path" --title "$title" "${notes_args[@]}" "$draft_flag" --repo "$repo"
        else
            gh release create "$tag" "$zip_path" "$dmg_path" "$stable_zip_path" "$stable_dmg_path" --title "$title" "${notes_args[@]}" --repo "$repo"
        fi
    fi

    echo "GitHub release ready:"
    echo "  https://github.com/${repo}/releases/tag/${tag}"
}

case "$BUILD_MODE" in
    FULL)
        build_full_binary
        ;;
    APP)
        build_app_bundle
        ;;
    BLE_ONLY)
        build_ble_only
        ;;
    DIST)
        build_dist
        ;;
    RELEASE)
        publish_release
        ;;
    *)
        echo "Invalid BUILD_MODE: $BUILD_MODE. Use FULL, APP, DIST, RELEASE or BLE_ONLY."
        exit 1
        ;;
esac

echo "Build successful! Executable: $BUILD_MODE mode ($BUILD_TYPE)"
