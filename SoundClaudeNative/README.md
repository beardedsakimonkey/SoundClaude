# SoundClaude native macOS app

This directory contains the native SwiftUI migration target. The Tauri app at
the repository root remains unchanged and buildable.

## Requirements

- macOS 14.2 or later
- Xcode with the macOS SDK
- The same SoundCloud application callback URL used by the Tauri app:
  `http://127.0.0.1:32148/callback`

## Configure credentials

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, then replace the
placeholder values. The local file is ignored by Git.

The client secret is suitable only for this personal development build. A
distributed desktop app cannot keep an embedded client secret confidential.
Use a trusted token-exchange service or another approved credential plan before
distribution.

## Run

Open `SoundClaude.xcodeproj`, select the `SoundClaude` scheme, and run the app.
macOS asks for System Audio Recording access when the process tap starts. If the
permission changes in System Settings, quit and reopen the app.

The initial target contains:

- OAuth authorization-code authentication with PKCE and a loopback callback
- Keychain token persistence and refresh
- `/me` and paginated `/me/likes/tracks` requests
- authenticated stream resolution with final CDN host validation
- one `AVPlayer` for Apple HLS/AAC playback
- a private Core Audio process tap for this app only
- a fixed-capacity atomic PCM ring and fixed spectrum snapshot
- an Accelerate FFT worker and an `MTKView` renderer

No custom HLS or audio decoder is present.
