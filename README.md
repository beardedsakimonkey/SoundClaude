# SoundClaude

https://github.com/user-attachments/assets/c4c8524f-6f96-49e1-a15f-4f4fc52a87a8

> [!NOTE]
> SoundClaude uses SoundCloud's website API with your own soundcloud.com sign-in,
> so it needs no API key. That API is undocumented, and SoundCloud can change it
> without notice.

SoundClaude is a native macOS SoundCloud client built with SwiftUI and Metal. It
features:

- Support for shuffling likes and artist tracks (beyond just the
  loaded tracks)
- Support for starting a station from the currently playing track without
  interrupting playback
- Support for dragging and dropping tracks into playlists and reordering queue items
- Each track gets an accent color derived from the track artwork
- Responsive design that looks good at all window sizes
- Light and dark modes (depending on OS setting)
- Built for desktop with hover feedback on interactive elements, right-click menus,
  and keyboard shortcuts
- Several physics-based music visualizers, including piston, rope, and fluid simulations
- Expandable track artwork and artist photos


## Requirements

- macOS 14.2 or later
- Xcode with the macOS SDK

## Install

Download `SoundClaude.dmg` from Releases, open it, and drag `SoundClaude.app` onto
the **Applications** folder. Eject the disk image, then open SoundClaude from
Applications. If you use the ZIP download, unzip it and move the app to
`/Applications`. The app isn't notarized, so macOS blocks the first launch: open it
once, then choose **Open Anyway** in **System Settings → Privacy & Security**. Or
run:

```sh
xattr -dr com.apple.quarantine /Applications/SoundClaude.app
```

## Package for distribution

Run `make dmg` to build a universal (Apple Silicon and Intel), ad-hoc-signed app
and package it as `build/SoundClaude.dmg` with a drag-to-Applications layout.
This uses the built-in macOS tools and requires a logged-in desktop session.
If macOS asks, allow your terminal to control Finder so it can save the layout.
The app is not notarized; the first-launch instructions above still apply.

Run `make dist` to produce `build/SoundClaude.zip` instead.

## Sign in

Choose **Sign in with SoundCloud** and sign in on the embedded soundcloud.com page.
SoundClaude keeps only the resulting website session token, in macOS Keychain;
**Sign Out** removes it.

If embedded sign-in does not work, use **Use an existing browser session** to
import a copied `oauth_token` cookie value from a signed-in soundcloud.com tab. The
import clears the clipboard.

SoundClaude finds the website's public client ID on soundcloud.com and finds it
again when SoundCloud rotates it.

> [!NOTE]
> macOS asks for System Audio Recording access when the process tap starts. This
> is needed for the audio visualizer.

## Attribution

The Fluid visualizer uses a Metal port of Pavel Dobryakov’s
[WebGL Fluid Simulation](https://github.com/PavelDoGreat/WebGL-Fluid-Simulation).
