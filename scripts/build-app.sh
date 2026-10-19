#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
binary_directory="$(swift build -c release --show-bin-path)"
app="$PWD/build/Webloc Thumbnails.app"
if [ -e "$app" ]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$bundle_id" != "com.behlock.webloc-thumbnails" ]; then
        printf 'Refusing to replace an unrelated app at %s\n' "$app" >&2
        exit 1
    fi
    rm -rf "$app"
fi
mkdir -p "$app/Contents/MacOS"
cp "$binary_directory/WeblocThumbnails" "$app/Contents/MacOS/"
cp App/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf 'Built %s\n' "$app"
