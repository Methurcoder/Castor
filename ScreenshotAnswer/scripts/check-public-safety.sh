#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
REPO_ROOT=${PROJECT_DIR:h}
PACKAGE_PATH="ScreenshotAnswer"

fail() {
    echo "error: $1" >&2
    exit 1
}

git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "Run this check from a Git checkout."

# These representative paths do not need to exist. They prove that future
# credentials and machine-local artifacts will remain outside Git.
typeset -a REQUIRED_IGNORES=(
    "$PACKAGE_PATH/Support/Signing.local"
    "$PACKAGE_PATH/Support/example.cer"
    "$PACKAGE_PATH/Support/example.p12"
    "$PACKAGE_PATH/Support/AuthKey_EXAMPLE.p8"
    "$PACKAGE_PATH/Support/example.pem"
    "$PACKAGE_PATH/Support/example.key"
    "$PACKAGE_PATH/Support/example.keychain-db"
    "$PACKAGE_PATH/.env"
    "$PACKAGE_PATH/.secrets/example"
    "$PACKAGE_PATH/.DS_Store"
    "$PACKAGE_PATH/Sources/.DS_Store"
    "$PACKAGE_PATH/.build/example"
    "$PACKAGE_PATH/dist/Screenshot Answer.app"
)

for ignored_path in "${REQUIRED_IGNORES[@]}"; do
    git -C "$REPO_ROOT" check-ignore --no-index -q "$ignored_path" \
        || fail "Sensitive or generated path is not ignored: $ignored_path"
done

typeset -a CANDIDATES=()
while IFS= read -r -d '' candidate_path; do
    CANDIDATES+=("$candidate_path")
done < <(
    git -C "$REPO_ROOT" ls-files \
        --cached \
        --others \
        --exclude-standard \
        -z \
        -- "$PACKAGE_PATH"
)

(( ${#CANDIDATES[@]} > 0 )) \
    || fail "No publishable ScreenshotAnswer source files were found."

typeset -a LOCAL_IDENTIFIERS=()
SIGNING_CONFIG_PATH="$PROJECT_DIR/Support/Signing.local"
if [[ -f "$SIGNING_CONFIG_PATH" ]]; then
    LOCAL_SIGNING_HASH=$(<"$SIGNING_CONFIG_PATH")
    printf '%s\n' "$LOCAL_SIGNING_HASH" | /usr/bin/grep -Eq '^[0-9A-Fa-f]{40}$' \
        && LOCAL_IDENTIFIERS+=("$LOCAL_SIGNING_HASH")
fi

IDENTITY_LIST=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)
while IFS= read -r identity_name; do
    [[ -n "$identity_name" ]] && LOCAL_IDENTIFIERS+=("$identity_name")
done < <(
    printf '%s\n' "$IDENTITY_LIST" \
        | /usr/bin/sed -n 's/^.*"\(Apple Development:.*\)".*$/\1/p'
)

BUILT_APP="$PROJECT_DIR/dist/Screenshot Answer.app"
if [[ -d "$BUILT_APP" ]]; then
    SIGNATURE_DETAILS=$(/usr/bin/codesign --display --verbose=4 "$BUILT_APP" 2>&1 || true)
    LOCAL_TEAM_ID=$(printf '%s\n' "$SIGNATURE_DETAILS" \
        | /usr/bin/awk -F= '/^TeamIdentifier=/ { print $2; exit }')
    if [[ -n "$LOCAL_TEAM_ID" && "$LOCAL_TEAM_ID" != "not set" ]]; then
        LOCAL_IDENTIFIERS+=("$LOCAL_TEAM_ID")
    fi
fi

for relative_path in "${CANDIDATES[@]}"; do
    absolute_path="$REPO_ROOT/$relative_path"
    [[ -f "$absolute_path" ]] || continue

    case "$relative_path" in
        *.cer|*.crt|*.p12|*.p8|*.pem|*.key|*.csr|*.certSigningRequest|*.keychain|*.keychain-db|*.mobileprovision|*.provisionprofile|*/Signing.local|*/.DS_Store)
            fail "Credential or machine-local file would be published: $relative_path"
            ;;
    esac

    /usr/bin/grep -Iq . "$absolute_path" || continue

    if /usr/bin/grep -Eq '/(Users|home)/[^/[:space:]\"]+' "$absolute_path"; then
        fail "Absolute home-directory path found in: $relative_path"
    fi

    if /usr/bin/grep -Eq '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[A-Za-z]{2,}' "$absolute_path"; then
        fail "Email address found in: $relative_path"
    fi

    for identifier in "${LOCAL_IDENTIFIERS[@]}"; do
        if [[ ${#identifier} -ge 8 ]] \
            && /usr/bin/grep -Fq "$identifier" "$absolute_path"; then
            fail "A local signing identifier was found in: $relative_path"
        fi
    done
done

echo "Public safety check passed (${#CANDIDATES[@]} publishable files inspected)."
