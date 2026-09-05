# SoundClaude

SoundClaude is a native macOS SoundCloud client built with SwiftUI, AVPlayer,
Core Audio, Accelerate, and Metal. It feautres:

- OAuth authorization-code authentication with PKCE and a loopback callback
- Keychain token persistence and refresh
- authenticated stream resolution with final CDN host validation
- one `AVPlayer` for Apple HLS/AAC playback
- saved track and playback position, restored paused at startup; cleared on sign-out
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
