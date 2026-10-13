#!/bin/bash
# Fetch only the matching app. No compiler, Python or administrator access needed.
set -euo pipefail
repo='Methurcoder/Castor'
fail() { printf '\nCastor: %s\n' "$1" >&2; exit 1; }
auth_hint=false
trap 'status=$?; [ -z "${work:-}" ] || rm -rf "$work"; if [ "$status" -ne 0 ] && $auth_hint; then printf "Releaseがない、または非公開の場合は、アクセス権と gh auth login を確認してください。\n" >&2; fi' EXIT
[ "$(uname -s)" = Darwin ] || fail 'This launcher is for macOS.'
version_os=$(sw_vers -productVersion)
major=${version_os%%.*}; rest=${version_os#*.}; minor=${rest%%.*}
[ "$major" -gt 26 ] || { [ "$major" -eq 26 ] && [ "$minor" -ge 5 ]; } || fail 'macOS 26.5 or later is required.'
arch=$(uname -m)
if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then arch=arm64; fi
case "$arch" in arm64) platform=macos_arm64;; x86_64) platform=macos_x86_64;; *) fail 'Unsupported CPU.';; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/castor-download.XXXXXXXX")
auth=false
if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then auth=true; fi
fetch_https() {
    local http_code
    if ! http_code=$(curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 \
        --write-out '%{http_code}' "$1" -o "$2"); then
        case "$http_code" in 401|404) auth_hint=true;; esac
        fail "GitHub download failed (HTTP ${http_code:-unknown})."
    fi
}
github_api() {
    local destination=$1
    shift
    if ! gh api "$@" > "$destination" 2> "$work/github-error"; then
        if /usr/bin/grep -Eqi 'HTTP (401|404)|gh auth login|not logged|requires authentication' "$work/github-error"; then
            auth_hint=true
        fi
        fail 'GitHub API request failed.'
    fi
}
if $auth; then
    github_api "$work/release.json" "repos/$repo/releases/latest"
else
    fetch_https "https://api.github.com/repos/$repo/releases/latest" "$work/release.json"
fi
# macOS includes JavaScript for Automation; all fields are validated before use.
json() {
    /usr/bin/osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('Foundation');
function run(args) {
    const data = $.NSData.dataWithContentsOfFile(args[1]);
    if (!data) throw Error('Could not read manifest');
    const obj = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)));
    if (args[0] === 'asset') {
        if (obj.draft || obj.prerelease) throw Error('Use a stable Release');
        const matches = obj.assets.filter(a => a.name === args[2]);
        if (matches.length !== 1) throw Error('Missing or duplicate release asset: '+args[2]);
        const a = matches[0];
        if (!Number.isSafeInteger(a.id) || a.id <= 0 || !a.browser_download_url.startsWith('https://github.com/Methurcoder/Castor/releases/download/')) throw Error('Unexpected asset');
        return a.id+'\t'+a.browser_download_url;
    }
    if (obj.schema !== 1 || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(obj.version)) throw Error('Invalid version');
    const a = obj.platforms[args[2]];
    if (!a) throw Error('No app for this CPU');
    const expected = 'Castor-'+obj.version+'-'+args[2]+'.zip';
    if (a.asset !== expected || !/^[a-f0-9]{64}$/.test(a.sha256) || !Number.isSafeInteger(a.bytes) || a.bytes <= 0) throw Error('Invalid app manifest');
    return [obj.version,a.asset,a.sha256,a.bytes].join('\t');
}
JXA
}
fetch() {
    local id url
    IFS=$'\t' read -r id url <<< "$(json asset "$work/release.json" "$1")"
    [ -n "$id" ] && [ -n "$url" ] || fail 'Missing release asset.'
    if $auth; then
        github_api "$2" -H 'Accept: application/octet-stream' "repos/$repo/releases/assets/$id"
    else
        fetch_https "$url" "$2"
    fi
}
fetch castor-downloads.json "$work/manifest.json"
fields=$(json manifest "$work/manifest.json" "$platform")
IFS=$'\t' read -r version asset checksum bytes <<< "$fields"
[ -n "$version" ] && [ -n "$asset" ] && [ -n "$checksum" ] || fail 'Invalid manifest.'
printf 'Downloading Castor %s (%s)…\n' "$version" "$platform"
fetch "$asset" "$work/app.zip"
[ "$(stat -f %z "$work/app.zip")" = "$bytes" ] || fail 'Download size does not match.'
actual=$(shasum -a 256 "$work/app.zip"); actual=${actual%% *}
[ "$actual" = "$checksum" ] || fail 'SHA-256 does not match; app was not installed.'
# Reject traversal and links before extracting. Release packager emits regular files only.
unzip -Z1 "$work/app.zip" > "$work/entries"
while IFS= read -r entry; do
    case "$entry" in /*|*\\*|../*|*/../*|*/..|..|*:* ) fail 'Unsafe ZIP path.';; esac
    case "$entry" in Castor.app/*|LICENSE|THIRD_PARTY_NOTICES.md) ;; *) fail 'Unexpected ZIP contents.';; esac
done < "$work/entries"
if zipinfo -l "$work/app.zip" | /usr/bin/grep -q '^l'; then fail 'Symbolic links are not supported.'; fi
mkdir "$work/app"
ditto -x -k "$work/app.zip" "$work/app"
[ -f "$work/app/Castor.app/Contents/Info.plist" ] && [ -x "$work/app/Castor.app/Contents/MacOS/Castor" ] || fail 'Castor.app is missing.'
base="$HOME/Applications"
mkdir -p "$base"
target="$base/Castor-$version-$platform"
# Atomic directory reservation prevents replacing an existing install.
mkdir "$target" || fail 'That version is already installed. The existing folder was kept.'
cp -R "$work/app/." "$target/"
printf 'Installed: %s\n' "$target"
open "$target"
