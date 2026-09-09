# SoundClaude

SoundClaude is a native macOS SoundCloud client built with SwiftUI, AVPlayer,
Core Audio, Accelerate, and Metal. It feautres:

- OAuth authorization-code authentication with PKCE and a loopback callback
- Keychain token persistence and refresh
- authenticated stream resolution with final CDN host validation
- one `AVPlayer` for Apple HLS/AAC playback
- saved track, queue source, and playback position, restored paused at startup; cleared on sign-out
- a locally cached feed with track and playlist posts, reposts, user avatars, and relative timestamps
- queues from the feed, likes, artist tracks and reposts, playlists, and related tracks
- account-specific likes metadata cached in Application Support; new likes sync when Likes opens
- account-specific playlist metadata and opened playlist tracks cached locally
- last sidebar selection restored for each account, including playlists
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

Enter a query in the search field at the top of the sidebar and press Return.
Search starts with tracks. Switch to Playlists or Users in the results view, and
use Load More to fetch another page. Playing a track starts a search results queue.

History loads up to 25 distinct recently played tracks from your SoundCloud account,
newest first. Use Refresh History to update the list. The API does not provide older
pages. Tracks unavailable for app playback are omitted.

Next and Previous use the list that started playback. Feed, artist, repost, playlist, and related
queues fetch another page when sequential playback reaches the end of the loaded
tracks. Enabling shuffle immediately shuffles the loaded tracks, with the current
track first. Track Queue shows this playback order, and Next and Previous follow
it without reshuffling. Turning shuffle off restores the order from before shuffle
was enabled. Shuffle does not fetch an entire artist catalog. Likes shuffle uses
the local library while sync runs in the background, adding new likes at the end.

Open Track Queue with the footer button or Q. It slides up above the footer at the
bottom right and stays open while you use shuffle and the other playback controls.
Close it with its close button, Q, or Escape. Drag a row by its handle to change the playback order.
Moving a track keeps the current track playing and leaves shuffle enabled if it
is on. The displayed order, including changes made while shuffled, is saved for
the next launch. Likes refreshes keep this order and add new likes at the end of
the queue.

The likes cache stores metadata as atomic JSON files in
`~/Library/Application Support/SoundClaude/Likes/`, separately for each account.
It contains no audio or resolved stream URLs. The first import saves each page;
an interrupted import resumes from its saved continuation. Later visits fetch the
newest pages until they overlap the cache. Local like changes are saved immediately.
Likes removed on another device can remain cached until a sync reaches the end
of the remote list, because the API has no incremental change feed. Sign-out clears
memory and playback state, and retains the account-specific cache for the next login.

The feed cache saves activity metadata in account-specific atomic JSON files in
`~/Library/Application Support/SoundClaude/Feed/`. Opening Feed restores saved
items, then refreshes from the newest page until it reaches the saved feed.
Older pages are saved as you scroll, including the continuation for the next visit.
Refresh Feed checks for new items on demand. Failed requests keep the saved
snapshot available. A complete refresh removes entries no longer returned by the
API; older entries can remain until that part of the feed is refreshed. Sign-out
clears memory and retains each account's cache. This stores metadata only;
playback still needs a network connection.

The playlist cache uses the same account-specific atomic JSON storage in
`~/Library/Application Support/SoundClaude/Playlists/`. The sidebar restores its
saved list before refreshing. Opening a playlist restores its saved details and
tracks, then fetches all current pages to detect removals and order changes.
Complete snapshots stay visible if refresh fails. Initial imports save each page;
interrupted imports restart from the first page on the next visit. Only playlists
you open have their tracks cached. Sign-out clears memory and retains the cache.
This stores metadata only; playback still needs a network connection.

Run the regression suites with `make test`.
