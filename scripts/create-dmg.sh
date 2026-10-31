#!/bin/sh
# Uses macOS tools only. Finder needs a logged-in desktop session.
set -eu

if [ "$#" -ne 2 ] || [ ! -d "$1" ]; then
    echo "Usage: $0 /path/to/SoundClaude.app /path/to/SoundClaude.dmg" >&2
    exit 1
fi

app=$1
output=$2
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d /tmp/soundclaude-dmg.XXXXXX)
mount_path="/Volumes/SoundClaude-Install-${work##*.}"
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then
        hdiutil detach "$mount_path" -quiet || {
            echo "Could not unmount $mount_path; temporary files left in $work" >&2
            return
        }
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$work/staging" "$(dirname "$output")"
mkdir -p "$work/staging/.background"
swift "$script_dir/generate-dmg-background.swift" "$work/staging/.background/gradient.tiff"
ditto "$app" "$work/staging/SoundClaude.app"
ln -s /Applications "$work/staging/Applications"
hdiutil create -quiet -srcfolder "$work/staging" -volname "Drag SoundClaude to Applications" \
    -fs HFS+ -format UDRW "$work/layout.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen \
    -mountpoint "$mount_path" "$work/layout.dmg"
mounted=true

osascript - "${mount_path##*/}" <<'APPLESCRIPT'
on run argv
    tell application "Finder"
        set imageDisk to disk (item 1 of argv)
        open imageDisk
        tell container window of imageDisk
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set bounds to {200, 200, 760, 520}
        end tell
        set viewOptions to icon view options of container window of imageDisk
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 14
        set background picture of viewOptions to file ".background:gradient.tiff" of imageDisk
        set position of item "SoundClaude.app" of imageDisk to {140, 130}
        set position of item "Applications" of imageDisk to {420, 130}
        close container window of imageDisk
        open imageDisk
        update imageDisk without registering applications
        delay 2
        close container window of imageDisk
    end tell
end run
APPLESCRIPT

# Finder writes the layout into .DS_Store on the mounted image.
if [ ! -f "$mount_path/.DS_Store" ]; then
    echo "Finder did not save the disk image layout." >&2
    exit 1
fi
sync
hdiutil detach -quiet "$mount_path"
mounted=false
hdiutil convert -quiet "$work/layout.dmg" -format UDZO -o "$work/release.dmg"
hdiutil verify "$work/release.dmg"
mv -f "$work/release.dmg" "$output"
printf '%s\n' "$output"
