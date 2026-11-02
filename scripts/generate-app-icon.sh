#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_icon="$repo_root/SoundClaude/SoundClaude/Resources/AppIcon.icon"
mkdir -p "$app_icon/Assets"

# Icon Composer's canvas is 1024pt and images are placed at their natural size,
# so anything larger gets cropped.
sips -z 1024 1024 "$repo_root/icon.png" --out "$app_icon/Assets/icon.png" > /dev/null
sips -z 1024 1024 "$repo_root/icon_dark.png" --out "$app_icon/Assets/icon_dark.png" > /dev/null

# macOS only honors dark app icons from a .icon bundle: actool silently drops
# dark variants in an .appiconset. Glass and specular are off to keep the
# artwork's colors, since it already has its own lighting.
cat > "$app_icon/icon.json" <<'EOF'
{
  "fill" : "automatic",
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name-specializations" : [
            { "value" : "icon.png" },
            { "appearance" : "dark", "value" : "icon_dark.png" }
          ],
          "name" : "icon"
        }
      ],
      "shadow" : { "kind" : "none", "opacity" : 0 },
      "specular" : false,
      "translucency" : { "enabled" : false, "value" : 0 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
EOF
