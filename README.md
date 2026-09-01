# SoundClaude

A small personal SoundCloud client built with Tauri 2, React, and TypeScript. It signs in to a SoundCloud account, shows ten recent liked tracks, and plays SoundCloud streams through the native macOS webview audio control.

## Setup

1. In the SoundCloud application settings, register this exact redirect URI:

   ```text
   http://127.0.0.1:32148/callback
   ```

2. Keep the existing `credentials.json` in the repository root. Its shape is:

   ```json
   {
     "client_id": "...",
     "client_secret": "..."
   }
   ```

   The file is ignored by Git. The Rust build validates it and embeds the credentials in the personal application binary. Do not publish the binary or this file. For a distributed application, move the token exchange to a trusted server and rotate the client secret.

3. Install dependencies and start the app:

   ```sh
   pnpm install
   pnpm tauri dev
   ```

SoundCloud opens in the default browser. The application listens on `127.0.0.1:32148` for up to five minutes and validates the OAuth state and PKCE response. If another process uses that port, close it and try again.

## Checks

```sh
pnpm test
pnpm build
cargo test --manifest-path src-tauri/Cargo.toml
pnpm tauri build --debug
```

OAuth access and refresh tokens are kept in `~/Library/Application Support/com.tim.soundclaude/oauth-session.json`. The directory uses owner-only permissions (`0700`), and the file uses owner-only permissions (`0600`). The React webview never receives these tokens or the SoundCloud client secret.

Playback uses the current SoundCloud flow: the Rust backend requests the track stream list, follows the selected stream endpoint with an authenticated `HEAD` request, validates the returned `sndcdn.com` host, and gives only that short-lived CDN URL to the audio element.
