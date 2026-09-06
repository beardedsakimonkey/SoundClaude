# SoundClaude

SoundClaude is a native macOS SoundCloud client built with SwiftUI, AVPlayer,
Core Audio, Accelerate, and Metal. It feautres:

- OAuth authorization-code authentication with PKCE and a loopback callback
- Keychain token persistence and refresh
- authenticated stream resolution with final CDN host validation
- one `AVPlayer` for Apple HLS/AAC playback
- saved track, queue source, and playback position, restored paused at startup; cleared on sign-out
- queues from likes, artist tracks and reposts, playlists, and related tracks
- account-specific likes metadata cached in Application Support; new likes sync when Likes opens
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

## Queues and likes

Next and Previous use the list that started playback. Artist, repost, playlist, and related
queues fetch another page when sequential playback reaches the end of the loaded
tracks. Shuffle uses the loaded tracks immediately. It does not fetch an entire
artist catalog. Likes shuffle uses the local library while sync runs in the background.

The likes cache stores metadata as atomic JSON files in
`~/Library/Application Support/SoundClaude/Likes/`, separately for each account.
It contains no audio or resolved stream URLs. The first import saves each page;
an interrupted import resumes from its saved continuation. Later visits fetch the
newest pages until they overlap the cache. Local like changes are saved immediately.
Likes removed on another device can remain cached until a sync reaches the end
of the remote list, because the API has no incremental change feed. Sign-out clears
memory and playback state, and retains the account-specific cache for the next login.

Run the regression suites with `make test`.
