#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_icon="$repo_root/icon.png"
catalog="$repo_root/SoundClaude/SoundClaude/Resources/Assets.xcassets"
app_icon="$catalog/AppIcon.appiconset"
mkdir -p "$app_icon"

printf '%s\n' '{ "info": { "author": "xcode", "version": 1 } }' > "$catalog/Contents.json"
{
    printf '{\n  "images": [\n'
    separator=''
    for size in 16 32 128 256 512; do
        for scale in 1 2; do
            pixels=$((size * scale))
            filename="icon_${size}x${size}@${scale}x.png"
            sips -z "$pixels" "$pixels" "$source_icon" --out "$app_icon/$filename" > /dev/null
            printf '%s    { "filename": "%s", "idiom": "mac", "scale": "%sx", "size": "%sx%s" }' "$separator" "$filename" "$scale" "$size" "$size"
            separator=',
'
        done
    done
    printf '\n  ],\n  "info": { "author": "xcode", "version": 1 }\n}\n'
} > "$app_icon/Contents.json"
