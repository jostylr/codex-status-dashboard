#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
bundle_path="$project_dir/.build/Codex Status Dashboard.app"
release_dir="$project_dir/.build/releases"
sign_identity="${DASHBOARD_SIGN_IDENTITY:-}"
notary_profile="${DASHBOARD_NOTARY_PROFILE:-}"

if [[ -z "$sign_identity" || "$sign_identity" == "-" ]]; then
    printf -u2 "Set DASHBOARD_SIGN_IDENTITY to your Developer ID Application identity."
    exit 1
fi
if [[ -z "$notary_profile" ]]; then
    printf -u2 "Set DASHBOARD_NOTARY_PROFILE to a notarytool keychain profile."
    exit 1
fi

DASHBOARD_SIGN_IDENTITY="$sign_identity" zsh "$script_dir/build-app.sh"

version="$(plutil -extract CFBundleShortVersionString raw "$bundle_path/Contents/Info.plist")"
archive_path="$release_dir/Codex-Status-Dashboard-$version.zip"
mkdir -p "$release_dir"
rm -f "$archive_path"

# Submit a ZIP that preserves the app bundle's metadata. After approval, staple
# the ticket to the app and recreate the ZIP so users receive the stapled copy.
ditto -c -k --sequesterRsrc --keepParent "$bundle_path" "$archive_path"
xcrun notarytool submit "$archive_path" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$bundle_path"
xcrun stapler validate "$bundle_path"
codesign --verify --deep --strict --verbose=2 "$bundle_path"
spctl --assess --type execute --verbose=4 "$bundle_path"

rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$bundle_path" "$archive_path"
shasum -a 256 "$archive_path"
printf "$archive_path"
