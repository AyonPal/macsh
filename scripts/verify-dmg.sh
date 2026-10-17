#!/usr/bin/env bash
# Checks release DMGs the way a user's Mac will treat them, without launching the app.
#
#   scripts/verify-dmg.sh dist/macsh-0.1.3.dmg [dist/macsh-lite-0.1.3.dmg ...]
#
# Per DMG: image checksum, drag-to-install layout, Info.plist, architecture, a valid code
# signature on the whole bundle, the bundled rclone (macsh only), and what Gatekeeper says
# about the app after a simulated download (quarantine flag). Exit status is non-zero if
# anything is wrong. "Rejected" by Gatekeeper is expected for apps without a Developer ID;
# "cannot assess" is not: that is what users see as "macsh is damaged and can't be opened".
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: $0 file.dmg [file.dmg ...]" >&2; exit 2; }

failures=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
note() { printf '  \033[33mNOTE\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failures=$((failures + 1)); }

verify_one() {
    local dmg="$1" work mnt app name
    echo "==> $dmg"
    [ -f "$dmg" ] || { fail "file not found"; return; }

    if hdiutil verify "$dmg" >/dev/null 2>&1; then pass "image checksum is valid"; else fail "hdiutil verify failed"; return; fi

    work="$(mktemp -d /tmp/verify-dmg.XXXXXX)"; mnt="$work/mnt"; mkdir "$mnt"
    # shellcheck disable=SC2064
    trap "hdiutil detach '$mnt' -quiet >/dev/null 2>&1; rm -rf '$work'" RETURN
    if ! hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null 2>&1; then fail "could not attach the image"; return; fi

    local apps; apps="$(find "$mnt" -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')"
    if [ "$apps" = 1 ]; then app="$(find "$mnt" -maxdepth 1 -name '*.app')"; name="$(basename "$app" .app)"; pass "contains exactly one app ($name.app)"; else fail "expected one .app at the top level, found $apps"; return; fi
    if [ -L "$mnt/Applications" ] && [ "$(readlink "$mnt/Applications")" = "/Applications" ]; then pass "Applications shortcut for drag-to-install"; else fail "no Applications -> /Applications symlink"; fi

    local plist="$app/Contents/Info.plist" bid ver
    bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)"
    ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
    if [ -n "$bid" ] && [ -n "$ver" ]; then pass "Info.plist: $bid $ver"; else fail "Info.plist lacks bundle id or version"; fi
    case "$dmg" in *"-$ver.dmg") pass "DMG file name matches version $ver";; *) note "file name does not end in -$ver.dmg";; esac

    local exe="$app/Contents/MacOS/$name"
    if [ -x "$exe" ] && lipo -archs "$exe" 2>/dev/null | grep -qw arm64; then pass "executable is arm64"; else fail "missing or non-arm64 executable"; fi
    local minos; minos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || true)"
    [ -n "$minos" ] && note "requires macOS $minos or later"

    local sig
    if sig="$(codesign --verify --deep --strict "$app" 2>&1)"; then
        pass "code signature is valid for the whole bundle"
    else
        fail "invalid code signature: ${sig##*: }  (users get 'damaged and can't be opened')"
    fi

    case "$name" in
        macsh-lite) [ -e "$app/Contents/Resources/rclone" ] && note "lite flavour contains rclone (unexpected)" || pass "lite flavour: no bundled rclone, as intended" ;;
        *)
            local rc="$app/Contents/Resources/rclone"
            if [ -x "$rc" ] && lipo -archs "$rc" 2>/dev/null | grep -qw arm64 && "$rc" version >/dev/null 2>&1; then
                pass "bundled rclone runs ($("$rc" version 2>/dev/null | head -1))"
            else fail "bundled rclone missing, not arm64, or does not run"; fi ;;
    esac

    # What Gatekeeper decides after a download: copy the app out, flag it like a browser would.
    cp -R "$app" "$work/dl.app" 2>/dev/null
    xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");verify-dmg;" "$work/dl.app" 2>/dev/null
    local gk; gk="$(spctl --assess --type execute -vv "$work/dl.app" 2>&1 | head -2 | tr '\n' ' ')"
    case "$gk" in
        *accepted*) pass "Gatekeeper accepts the downloaded app (signed and notarized)" ;;
        *"code has no resources"*|*"sealed resource"*|*"a sealed resource is missing"*|*invalid*)
            fail "Gatekeeper cannot assess the downloaded app: $gk" ;;
        *rejected*) note "Gatekeeper rejects it as expected without a Developer ID: users open it via right-click > Open or System Settings > Privacy & Security > Open Anyway" ;;
        *) note "Gatekeeper said: $gk" ;;
    esac
}

for dmg in "$@"; do verify_one "$dmg"; done
echo
if [ "$failures" -eq 0 ]; then echo "All checks passed."; else echo "$failures check(s) failed."; fi
exit $(( failures > 0 ? 1 : 0 ))
