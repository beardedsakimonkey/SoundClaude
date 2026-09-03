#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
build_dir="$script_dir/build"
app_dir="$build_dir/SoundClaudeAudioProbe.app"
binary_dir="$app_dir/Contents/MacOS"
target_arch=$(uname -m)

mkdir -p "$binary_dir"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"

xcrun swiftc \
    -O \
    -parse-as-library \
    -target "$target_arch-apple-macosx14.2" \
    -framework Accelerate \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreAudio \
    "$script_dir/Sources/main.swift" \
    -o "$binary_dir/SoundClaudeAudioProbe"

codesign \
    --force \
    --sign - \
    --options runtime \
    --entitlements "$script_dir/AudioProbe.entitlements" \
    "$app_dir"
print -r -- "$app_dir"
