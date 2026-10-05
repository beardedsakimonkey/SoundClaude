# SoundClaude

https://github.com/user-attachments/assets/071d9ff1-36c6-42a5-9b89-5cef9f318aae

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
- Several physics-based music visualizers, including cloth, rope, and fluid
  simulations
- Expandable track artwork and artist photos

## Requirements

- macOS 14.2 or later
- Xcode with the macOS SDK
- This SoundCloud application callback URL:
  `http://127.0.0.1:32148/callback`

## Configure credentials

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, then replace the
placeholder values. The local file is ignored by Git.

The client secret is suitable only for this personal development build. A
distributed desktop app cannot keep an embedded client secret confidential.
Use a trusted token-exchange service or another approved credential plan before
distribution.

## Run

To build and run from the command line:

```sh
make
```

To build and run the app with the Release configuration:

```sh
make release
```

The app is saved to `SoundClaude/DerivedData/Build/Products/Release/SoundClaude.app`.

To run the regression suites:

```
make test
```

To configure SourceKit-LSP and refresh its build data:

```sh
make lsp
```

macOS asks for System Audio Recording access when the process tap starts.

## API specification

Run `make api` to replace the local `api.yaml` with the latest specification from
the [SoundCloud API repository](https://github.com/soundcloud/api/blob/master/openapi/api.yaml).
If the download fails, the local file stays unchanged.

## App icon

The source image is `icon.png`. After you replace it with a square PNG, run
`make icon` to regenerate the macOS icon sizes, rebuild the app, and refresh
its registration with macOS. Quit and reopen the app to use the updated icon.
If the Dock or app switcher still shows the old icon, run `killall Dock` to
restart the Dock and refresh its display.
