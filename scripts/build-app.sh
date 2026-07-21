#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
bundle_path="$project_dir/.build/Codex Status Dashboard.app"
iconset_path="$project_dir/.build/AppIcon.iconset"
sign_identity="${DASHBOARD_SIGN_IDENTITY:--}"
architectures=(arm64 x86_64)

for required_tool in rsvg-convert iconutil lipo codesign; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        printf -u2 "Missing required tool: $required_tool"
        if [[ "$required_tool" == "rsvg-convert" ]]; then
            printf -u2 "Install it with: brew install librsvg"
        fi
        exit 1
    fi
done

cd "$project_dir"

dashboard_binaries=()
helper_binaries=()
for architecture in "${architectures[@]}"; do
    scratch_path="$project_dir/.build/universal-$architecture"
    target_triple="$architecture-apple-macosx13.0"
    swift build \
        --configuration release \
        --scratch-path "$scratch_path" \
        --triple "$target_triple"
    binary_path="$(swift build \
        --configuration release \
        --scratch-path "$scratch_path" \
        --triple "$target_triple" \
        --show-bin-path)"
    dashboard_binaries+=("$binary_path/codex-status-dashboard")
    helper_binaries+=("$binary_path/codex-status-hook")
done

# The bundle and iconset are generated artifacts. Recreate them so removed or
# renamed resources from an older build cannot leak into a release.
rm -rf "$bundle_path" "$iconset_path"
mkdir -p \
    "$bundle_path/Contents/MacOS" \
    "$bundle_path/Contents/Helpers" \
    "$bundle_path/Contents/Resources" \
    "$iconset_path"

cp "Resources/Info.plist" "$bundle_path/Contents/Info.plist"
lipo -create "${dashboard_binaries[@]}" \
    -output "$bundle_path/Contents/MacOS/codex-status-dashboard"
lipo -create "${helper_binaries[@]}" \
    -output "$bundle_path/Contents/Helpers/codex-status-hook"
chmod 755 \
    "$bundle_path/Contents/MacOS/codex-status-dashboard" \
    "$bundle_path/Contents/Helpers/codex-status-hook"

rsvg-convert --width 16 --height 16 Resources/AppIcon.svg --output "$iconset_path/icon_16x16.png"
rsvg-convert --width 32 --height 32 Resources/AppIcon.svg --output "$iconset_path/icon_16x16@2x.png"
rsvg-convert --width 32 --height 32 Resources/AppIcon.svg --output "$iconset_path/icon_32x32.png"
rsvg-convert --width 64 --height 64 Resources/AppIcon.svg --output "$iconset_path/icon_32x32@2x.png"
rsvg-convert --width 128 --height 128 Resources/AppIcon.svg --output "$iconset_path/icon_128x128.png"
rsvg-convert --width 256 --height 256 Resources/AppIcon.svg --output "$iconset_path/icon_128x128@2x.png"
rsvg-convert --width 256 --height 256 Resources/AppIcon.svg --output "$iconset_path/icon_256x256.png"
rsvg-convert --width 512 --height 512 Resources/AppIcon.svg --output "$iconset_path/icon_256x256@2x.png"
rsvg-convert --width 512 --height 512 Resources/AppIcon.svg --output "$iconset_path/icon_512x512.png"
rsvg-convert --width 1024 --height 1024 Resources/AppIcon.svg --output "$iconset_path/icon_512x512@2x.png"
iconutil --convert icns "$iconset_path" --output "$bundle_path/Contents/Resources/AppIcon.icns"

if [[ "$sign_identity" == "-" ]]; then
    codesign --force --options runtime --sign - \
        "$bundle_path/Contents/Helpers/codex-status-hook"
    codesign --force --options runtime --sign - "$bundle_path"
    printf "Created an ad-hoc signed development bundle."
else
    codesign --force --options runtime --timestamp --sign "$sign_identity" \
        "$bundle_path/Contents/Helpers/codex-status-hook"
    codesign --force --options runtime --timestamp --sign "$sign_identity" "$bundle_path"
    printf "Signed with: $sign_identity"
fi

codesign --verify --deep --strict --verbose=2 "$bundle_path"
printf "Architectures: $(lipo -archs "$bundle_path/Contents/MacOS/codex-status-dashboard")"
printf "$bundle_path"
