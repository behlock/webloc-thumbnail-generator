#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
application_directory="${1:-$HOME/Applications}"
destination="$application_directory/Webloc Thumbnails.app"
if [ -e "$destination" ]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$bundle_id" != "com.behlock.webloc-thumbnails" ]; then
        printf 'Refusing to replace an unrelated app at %s\n' "$destination" >&2
        exit 1
    fi
    swift scripts/stop-app.swift
fi
mkdir -p "$application_directory"
launch_services=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ "$(cd "$application_directory" && pwd)/Webloc Thumbnails.app" != "$PWD/build/Webloc Thumbnails.app" ]; then
    if [ -d "$destination" ]; then rm -rf "$destination"; fi
    ditto "build/Webloc Thumbnails.app" "$destination"
    "$launch_services" -u "$PWD/build/Webloc Thumbnails.app" >/dev/null 2>&1 || true
fi
"$launch_services" -f "$destination"
"$destination/Contents/MacOS/WeblocThumbnails" --register-services
printf 'Installed %s\nSelect .webloc files in Finder, then choose Services > Generate Website Thumbnails.\n' "$destination"
