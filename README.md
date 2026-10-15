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
- Several physics-based music visualizers, including cloth, rope, and fluid simulations
- Expandable track artwork and artist photos


## Requirements

- macOS 14.2 or later
- Xcode with the macOS SDK
- This SoundCloud application callback URL:
  `http://127.0.0.1:32148/callback`

## Configure credentials

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, then replace the
placeholder values. The local file is ignored by Git.

## Run

To build and run from the command line:

```sh
make
```

To build and run the app with the Release configuration:

```sh
make release
```

To run the regression suites:

```
make test
```

To configure SourceKit-LSP and refresh its build data:

```sh
make lsp
```

To replace the local `api.yaml` with the latest specification from
the [SoundCloud API repository](https://github.com/soundcloud/api/blob/master/openapi/api.yaml):

```sh
make api
```


> [!NOTE]
> macOS asks for System Audio Recording access when the process tap starts.

## Acknowledgements

The Fluid visualizer uses a Metal port of Pavel Dobryakov’s
[WebGL Fluid Simulation](https://github.com/PavelDoGreat/WebGL-Fluid-Simulation).

## Visualize SwiftUI updates

Run a Debug build with `make run`, then select **Debug → Highlight View Updates**
(or press **⌘⌥⇧U**). Instrumented pages, track cards, grid tiles, waveforms,
sidebar, queue, and player show named borders that change color when their
SwiftUI `body` is evaluated. The setting is saved across launches.

These marks show body evaluations, not layout passes or actual screen redraws.
They add drawing overhead, so turn them off when measuring performance.
The menu and instrumentation are excluded from Release builds.

To instrument another view, add this to the root view expression inside its
`body` (calling it on a child from the parent measures the parent's evaluation):

```swift
#if DEBUG
.debugViewUpdates("MyView")
#endif
```

## Measure app launch

Build with `make build CONFIGURATION=Release`. Quit the running app, then run:

```sh
SOUNDCLAUDE_LAUNCH_TIMINGS=1 SoundClaude/DerivedData/Build/Products/Release/SoundClaude.app/Contents/MacOS/SoundClaude
```

The terminal reports elapsed milliseconds from the start of app initialization
and the duration of each measured step. It covers model setup, Keychain access,
player setup, queue and history restoration, library cache reads and sync,
session validation, and playback restoration. Cache intervals separate disk reads,
decoding, and publishing; playback intervals separate stream resolution from
player item attachment. Publishing measures synchronous updates and observers,
not the later SwiftUI layout work they trigger. Repeated library operations also
produce intervals, so use the initial entries when comparing launches.
No account data or credentials are logged. Console output is off by default.

For CPU stacks and a timeline, open the project in Xcode, select **Product →
Profile**, and choose **App Launch** or **Time Profiler**. Add the **os_signpost**
instrument to inspect the `SoundClaude` subsystem's `Launch` intervals alongside
CPU work. Signposts are available in both Debug and Release builds.

If Instruments launches a different installed build, quit it and start a recording
of all processes first:

```sh
xcrun xctrace record --template 'Time Profiler' --instrument os_signpost \
  --all-processes --time-limit 15s --output /tmp/SoundClaude-launch.trace
```

While recording, launch the Release executable from another terminal with the
command above. Filter the trace to that process and verify its executable path.
Use a new output filename for each recording. Compare console timings from
separate runs without Instruments to avoid including profiling overhead.

“Root view appeared” and “Signed-in view appeared” are SwiftUI appearance
callbacks, not proof that a frame reached the display. “Startup task finished”
means `AppModel.start()` returned; session validation and view tasks can still
be running. Use App Launch to measure process startup and rendering before or
beyond these application markers.

Compare several Release launches with the same account, selected page, and
cache state. Record cold and warm cache results separately. Durations include
network waits and task suspension; nested and concurrent intervals overlap and
must not be added together. Use CPU stacks to locate main-thread work, and the
intervals to identify slow cache or network operations. Keep view update
highlighting off when profiling Debug builds.

### Deferred startup work

Playlist startup restoration reads only the sidebar list. Track contents load
when a playlist is opened and are saved in separate files. Old combined caches
remain available; the first request for each playlist reads its entry and writes
a separate file. List refreshes preserve unopened contents. Removed playlists
get a deletion marker so their old cached tracks cannot return.

Saved playback restores its title, artwork, and position without resolving audio.
Play starts stream resolution and next-track preparation. Seeking while paused
updates the saved resume point. This moves the network wait to the first Play.

On October 15, 2026, five Release launches per build used the same account,
selected page, paused track, and restored disk-cache snapshot. These were warm
filesystem-cache runs without Instruments. The playlist cache contained 465
content entries and 9,387 tracks, while the sidebar list had three entries.
Medians from `SOUNDCLAUDE_LAUNCH_TIMINGS`:

| Measurement | Before | After |
| --- | ---: | ---: |
| Root view appeared | 285.5 ms | 296.2 ms |
| Startup task finished | 1,459.7 ms | 601.1 ms |
| Full playlist cache decode | 123.1 ms | Not performed |
| Current/next stream resolution while paused | Performed | Not performed |

The startup-task marker improved by 858.6 ms (59%). This is completion of
background startup work, not a measured rendering improvement: the root-view
callback was slightly later. Network times vary, and these runs do not measure
cold launches or end-to-end first-Play latency. A separate Release UI check
confirmed playback resumed from the saved position; current-track stream
resolution took 739.4 ms after Play. This is one network sample, not a latency
guarantee. Raw local logs are in
`/tmp/soundclaude-startup-benchmark/{before,after}-*.log` and `manual-play.log`.

## Inspect network activity

In a Debug build, select **Debug → Network Activity** (⌘⌥⇧N). The window
records requests from app launch and keeps the latest 500 attempts in memory.
Filter by API, artwork, other requests, or failures; search by URL or method.
Select a row for request and response headers. Each rate-limit retry has its
own row and attempt number. Durations cover each request, excluding retry waits;
bytes are the response data size, not total wire traffic.

**Pause** stops recording new requests; pending rows still finish. **Clear**
removes the current history. Recording is not saved to disk. Query values,
URL credentials, fragments, and all but a small set of content headers are
hidden. Bodies are not recorded. The window covers API, authentication,
artwork, profile HTML, and waveform requests through `SoundCloudClient`.
It excludes artwork cache hits, browser sign-in traffic, and AVPlayer audio
downloads. Automatic redirects appear as part of the original request.
The window and recording code are excluded from Release builds.

Run `make test-network-activity` to check redaction and recording controls.
