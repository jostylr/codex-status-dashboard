#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
bundle_path="$project_dir/.build/Codex Status Dashboard.app"
iconset_path="$project_dir/.build/AppIcon.iconset"

cd "$project_dir"
swift build -c release

mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Helpers" "$bundle_path/Contents/Resources" "$iconset_path"
cp "Resources/Info.plist" "$bundle_path/Contents/Info.plist"
cp ".build/release/codex-status-dashboard" "$bundle_path/Contents/MacOS/codex-status-dashboard"
cp ".build/release/codex-status-hook" "$bundle_path/Contents/Helpers/codex-status-hook"

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

echo "$bundle_path"
