# SoundClaude

<img width="2780" height="1838" alt="CleanShot 2026-09-17 at 12 08 10 PM@2x" src="https://github.com/user-attachments/assets/570a9845-55ef-4092-b2c4-bf6cb8a6fc6b" />

> [!NOTE]
> This app requires a SoundCloud Client ID/Secret to use, which requires an
> Artist Pro account. [Get an API Key](https://developers.soundcloud.com/docs/api/register-app#2-artist-pro-subscription-required)


SoundClaude is a native macOS SoundCloud client built with SwiftUI, AVPlayer,
Core Audio, Accelerate, and Metal. It feautres:

- OAuth authorization-code authentication with PKCE and a loopback callback
- Keychain token persistence and refresh
- immediate launch from the saved account profile, with session validation in the background
- authenticated stream resolution with final CDN host validation
- one `AVPlayer` for Apple HLS/AAC playback
- saved track, queue source, and playback position, with automatic resume at startup if playback was active at quit; cleared on sign-out
- a locally cached feed with track and playlist posts, reposts, user avatars, and relative timestamps
- queues from the feed, likes, artist tracks and reposts, playlists, and related tracks
- account-specific likes metadata cached in Application Support; new likes sync when Likes opens
- account-specific playlist metadata and opened playlist tracks cached locally
- last library selection restored for each account; sidebar playlists open in the current navigation stack
- sidebar search for tracks, playlists, and users, with paged results and track queues
- a private Core Audio process tap for this app only
- a fixed-capacity atomic PCM ring and fixed spectrum snapshot
- an Accelerate FFT worker and an `MTKView` renderer

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

To build the app with the Release configuration:

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

## App icon

The source image is `icon.png`. After you replace it with a square PNG, run
`make icon` to regenerate the macOS icon sizes, rebuild the app, and refresh
its registration with macOS. Quit and reopen the app to use the updated icon.
If the Dock or app switcher still shows the old icon, run `killall Dock` to
restart the Dock and refresh its display.
