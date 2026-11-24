<img width="100" height="100" alt="soundclaude-icon" src="https://github.com/user-attachments/assets/9d006658-a230-45e7-889a-ec46fb5d457a" />

# SoundClaude

SoundClaude is a native macOS SoundCloud client built with SwiftUI and Metal. It
hits SoundCloud's undocumented website API so it doesn't need an API key or a
third-party server.

## Features

- 📻 Start a station without interrupting the currently playing track
- 🫳 Drag-and-drop tracks to quickly add them to a playlist
- 🎨 UI that adapts to the track artwork's derived accent color
- 🌓 Light and dark mode support
- 🔀 Shuffle your liked tracks completely, instead of just the loaded tracks
- 🖥️ Built for desktop: right-click menus, keyboard shortcuts, and hover feedback
- 🔊 A 3D physics-based music visualizer

## Requirements

- macOS 14.2 or later
- Xcode with the macOS SDK

## Install

Download `SoundClaude.dmg` from Releases, open it, and drag `SoundClaude.app` onto
the **Applications** folder. Eject the disk image, then open SoundClaude from
Applications. The app isn't notarized, so macOS blocks the first launch: open it
once, then choose **Open Anyway** in **System Settings → Privacy & Security**. Or
run:

```sh
xattr -dr com.apple.quarantine /Applications/SoundClaude.app
```

## Sign in

Choose **Sign in with SoundCloud** and sign in on the embedded soundcloud.com page.
SoundClaude keeps only the resulting website session token in macOS Keychain.

Alternatively, use **Use an existing browser session** to import a copied
`oauth_token` cookie value from a signed-in soundcloud.com tab. The import
clears the clipboard.
