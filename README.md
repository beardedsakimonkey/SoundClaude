# SoundClaude

https://github.com/user-attachments/assets/c4c8524f-6f96-49e1-a15f-4f4fc52a87a8

> [!NOTE]
> This app requires a SoundCloud client ID and secret, which require an
> Artist Pro account. [Get an API Key](https://developers.soundcloud.com/docs/api/register-app#2-artist-pro-subscription-required)

SoundClaude is a native macOS SoundCloud client built with SwiftUI, AVPlayer,
Core Audio, Accelerate, and Metal. It features:

- Support for shuffling likes and artist tracks (beyond just the
  loaded tracks)
- Cached playlist and station shortcuts in the sidebar
- Support for search, feed, and history
- Support for starting a station from the currently playing track without
  interrupting playback
- Support for dragging and dropping tracks into playlists and reordering queue items
- Each track gets an accent color derived from the track artwork, used for
  various UI elements, including the waveform
- Responsive design that looks good at all window sizes
- Light and dark modes
- Built for desktop with hover feedback on interactive elements, right-click menus,
  and keyboard shortcuts
- Several physics-based music visualizers, including cloth, rope, and fluid simulations
- Expandable track artwork and artist photos


## Requirements

- macOS 14.2 or later
- Xcode with the macOS SDK
- This SoundCloud application callback URL:
  `http://127.0.0.1:32148/callback`

## Configure credentials

Copy `SoundClaude/Config/Configuration.xcconfig.example` to
`SoundClaude/Config/Configuration.xcconfig`, then replace the placeholder values
with your credentials.

## Run

To build and run from the command line:

```sh
make
```

To build and run the app with the Debug configuration:

```sh
make debug
```

> [!NOTE]
> macOS asks for System Audio Recording access when the process tap starts.

## Attribution

The Fluid visualizer uses a Metal port of Pavel Dobryakov’s
[WebGL Fluid Simulation](https://github.com/PavelDoGreat/WebGL-Fluid-Simulation).
