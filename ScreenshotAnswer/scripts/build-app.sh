#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/Screenshot Answer.app"
ARCHIVE_PATH="$DIST_DIR/Screenshot Answer.zip"
CONTENTS_DIR="$APP_DIR/Contents"
ICONSET_DIR="$PROJECT_DIR/.build/ScreenshotAnswer.iconset"
ICON_SOURCE="$PROJECT_DIR/.build/ScreenshotAnswer-AppIcon-1024.png"
EXPECTED_BUNDLE_ID="dev.pomegranate.screenshot-answer.prototype"
SIGNING_CONFIG_PATH="$PROJECT_DIR/Support/Signing.local"

fail() {
    echo "error: $1" >&2
    exit 1
}

# TCCの画面収録許可を再ビルド後も安定して追跡できるよう、ad-hoc署名は許可しない。
# 秘密鍵や証明書をリポジトリに保存せず、login keychain内のApple Development証明書を使う。
IDENTITY_LIST=$(/usr/bin/security find-identity -v -p codesigning)
SIGNING_IDENTITY_HASH=${SCREENSHOT_ANSWER_SIGNING_IDENTITY_HASH:-}
SHOULD_PIN_IDENTITY=false

if [[ -z "$SIGNING_IDENTITY_HASH" && -f "$SIGNING_CONFIG_PATH" ]]; then
    IFS= read -r SIGNING_IDENTITY_HASH < "$SIGNING_CONFIG_PATH"
fi

if [[ -n "$SIGNING_IDENTITY_HASH" ]]; then
    SIGNING_IDENTITY_HASH=$(printf '%s' "$SIGNING_IDENTITY_HASH" | /usr/bin/tr '[:lower:]' '[:upper:]')
    printf '%s\n' "$SIGNING_IDENTITY_HASH" | /usr/bin/grep -Eq '^[0-9A-F]{40}$' \
        || fail "SCREENSHOT_ANSWER_SIGNING_IDENTITY_HASH must be a 40-character certificate SHA-1 hash."
else
    typeset -a APPLE_DEVELOPMENT_IDENTITIES
    APPLE_DEVELOPMENT_IDENTITIES=()
    while IFS= read -r identity; do
        [[ -n "$identity" ]] && APPLE_DEVELOPMENT_IDENTITIES+=("$identity")
    done < <(printf '%s\n' "$IDENTITY_LIST" | /usr/bin/awk '/"Apple Development:/ { print $2 }')

    case ${#APPLE_DEVELOPMENT_IDENTITIES[@]} in
        0)
            fail "No valid Apple Development signing identity was found. Create one in Xcode > Settings > Accounts > Manage Certificates, then run this script again. ad-hoc fallback is disabled."
            ;;
        1)
            SIGNING_IDENTITY_HASH=${APPLE_DEVELOPMENT_IDENTITIES[1]}
            SHOULD_PIN_IDENTITY=true
            ;;
        *)
            fail "Multiple Apple Development identities were found. Set SCREENSHOT_ANSWER_SIGNING_IDENTITY_HASH to the exact certificate hash to choose one."
            ;;
    esac
fi

IDENTITY_RECORD=$(printf '%s\n' "$IDENTITY_LIST" | /usr/bin/awk -v identity="$SIGNING_IDENTITY_HASH" \
    '$2 == identity && /"Apple Development:/ { print; exit }')
[[ -n "$IDENTITY_RECORD" ]] \
    || fail "The selected certificate is not a valid Apple Development code-signing identity in the current keychain."

if [[ "$SHOULD_PIN_IDENTITY" == true ]]; then
    umask 077
    printf '%s\n' "$SIGNING_IDENTITY_HASH" > "$SIGNING_CONFIG_PATH"
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJECT_DIR/Support/Info.plist")
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] \
    || fail "Unexpected bundle identifier '$BUNDLE_ID'; expected '$EXPECTED_BUNDLE_ID'. Refusing to sign a different app."

cd "$PROJECT_DIR"
swift build -c release --product ScreenshotAnswer

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp ".build/release/ScreenshotAnswer" "$CONTENTS_DIR/MacOS/ScreenshotAnswer"
cp "Support/Info.plist" "$CONTENTS_DIR/Info.plist"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
sips -s format png -z 1024 1024 "Support/AppIcon.svg" --out "$ICON_SOURCE" >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS_DIR/Resources/AppIcon.icns"
codesign --force --deep --sign "$SIGNING_IDENTITY_HASH" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

SIGNATURE_DETAILS=$(codesign --display --verbose=4 "$APP_DIR" 2>&1)
DESIGNATED_REQUIREMENT=$(codesign --display --requirements - "$APP_DIR" 2>&1)
[[ "$SIGNATURE_DETAILS" == *"Authority=Apple Development:"* ]] \
    || fail "The built app is not signed by an Apple Development certificate."
[[ "$SIGNATURE_DETAILS" != *"Signature=adhoc"* ]] \
    || fail "The built app unexpectedly has an ad-hoc signature."
[[ "$SIGNATURE_DETAILS" == *"Identifier=$EXPECTED_BUNDLE_ID"* ]] \
    || fail "The signed app has an unexpected bundle identifier."
[[ "$SIGNATURE_DETAILS" == *"TeamIdentifier="* && "$SIGNATURE_DETAILS" != *"TeamIdentifier=not set"* ]] \
    || fail "The signed app has no stable Apple Developer Team identifier."
[[ "$DESIGNATED_REQUIREMENT" != *"designated => cdhash"* ]] \
    || fail "The designated requirement is still tied to a build-specific cdhash."

rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"
unzip -t "$ARCHIVE_PATH" >/dev/null

echo "Signed with an Apple Development certificate."
echo "Built: $APP_DIR"
echo "Built: $ARCHIVE_PATH"
