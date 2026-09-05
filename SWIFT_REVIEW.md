# Swift simplification and performance review

Date: 2026-09-04

Scope: the Swift code and its audio/Metal boundary. This was a static review;
performance impact is estimated from the code, not measured with Instruments.
No implementation changes were made as part of the review.

## Main opportunities

### 1. Reduce playback-driven view updates

[`PlaybackController.swift:50`](SoundClaude/SoundClaude/Playback/PlaybackController.swift#L50)
publishes time and duration every 250 ms.
[`LikesView.swift:13`](SoundClaude/SoundClaude/Likes/LikesView.swift#L13)
observes that entire controller but only uses `currentTrack`. This invalidates
the likes view throughout playback.

Migrate this controller to `@Observable` to narrow updates and remove some
wrapper boilerplate. The app's macOS 14.2 target supports it. Also avoid assigning
unchanged duration values. A local Combine probe confirmed that repeated
same-value `@Published` assignments still emit notifications.

Status: addressed. `PlaybackController` now uses `@Observable`, and its three
views track the playback properties they read. The footer uses `@Bindable` for
volume. The periodic callback skips unchanged duration values. A Release build
and a local audio playback probe passed; the probe checked isolated time
updates, duration notifications, track changes, volume binding, mute, and pause.

Reference: [Apple's Observation migration guide](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro).

### 2. Stop visualizer work when idle

[`MetalVisualizerView.swift:26`](SoundClaude/SoundClaude/Visualizer/MetalVisualizerView.swift#L26)
continuously draws at 60 or 120 FPS, even before playback. After playback starts,
pausing also leaves the analyzer timer running at roughly 94 wakeups per second
at 48 kHz.

Coordinate capture, analysis, and rendering with playback and window visibility.
This looks like the strongest battery-use opportunity.

### 3. Coalesce seek requests during dragging

[`TrackWaveformView.swift:67`](SoundClaude/SoundClaude/App/TrackWaveformView.swift#L67)
and the footer slider send seeks on every input update.
[`PlaybackController.swift:145`](SoundClaude/SoundClaude/Playback/PlaybackController.swift#L145)
makes every seek sample-accurate.

Use local drag state and commit on release, or allow one seek at a time while
retaining the latest target. Apple documents that rapid seeks cancel prior seeks
and can cause lag.

Status: addressed. `PlaybackController` now runs one seek at a time and retains
only the latest target from the waveform, footer, keyboard, or remote controls.
The displayed time follows that target while seeking, and repeated relative
seeks accumulate from it. Requests wait for the item to become ready. Loading
another track clears pending seeks, and callbacks from the old item are ignored.
A Release build and a local audio playback probe passed. The probe checked rapid
requests, duplicate targets, loading, time display, input bounds, relative seeks,
interrupted seeks, track replacement, and play/pause behavior.

Reference: [Apple's seeking guidance](https://developer.apple.com/library/archive/qa/qa1820/_index.html).

### 4. Simplify the Metal data upload

[`VisualizerRenderer.swift:61`](SoundClaude/SoundClaude/Visualizer/VisualizerRenderer.swift#L61)
overwrites one shared buffer every frame without waiting for earlier GPU reads.
The spectrum is only 256 bytes. `setFragmentBytes` would give each draw its own
copied data and remove manual buffer ownership. This also addresses a possible
CPU/GPU race.

The shader's unused `resolution` and `time` fields can go too.

Status: addressed. The renderer now reads the 64 spectrum bands into a reusable
Swift array and uploads them with `setFragmentBytes`, which copies the data for
each draw. The shared Metal buffer and elapsed-time tracking are removed. The
Swift and Metal uniform structs now contain only `energy`. A Release build
passed, including Swift and Metal compilation. Runtime rendering was not checked.

Reference: [Apple's `setFragmentBytes` guidance](https://developer.apple.com/documentation/metal/mtlrendercommandencoder/setfragmentbytes(_:length:index:)).

### 5. Keep the process tap across track changes

[`AppModel.swift:102`](SoundClaude/SoundClaude/App/AppModel.swift#L102)
stops capture for every selection, then starts it again when the item becomes
ready. That recreates the tap, aggregate device, and IO procedure for the same
process.

Reuse the running tap across item replacements, with explicit handling for
format changes and shutdown. This reduces setup work and visualizer gaps.

### 6. Precompute values that do not change during playback

[`SpectrumAnalyzer.swift:220`](SoundClaude/SoundClaude/Audio/SpectrumAnalyzer.swift#L220)
recalculates frequency boundaries using 128 `pow` calls per analysis. Compute
the bin ranges when the sample rate changes.

[`TrackWaveformView.swift:141`](SoundClaude/SoundClaude/App/TrackWaveformView.swift#L141)
also scans samples and rebuilds the entire path on every redraw. Cache it by
waveform and drawing size so progress only changes the clip.

### 7. Fetch larger likes pages

[`SoundCloudClient.swift:85`](SoundClaude/SoundClaude/Networking/SoundCloudClient.swift#L85)
requests only 10 tracks. The local
[`api.yaml:1221`](api.yaml#L1221) permits 200 and defaults to 50.

Using 50 means roughly five times fewer page requests when browsing a large
library, with a larger initial response as the tradeoff.

Status: addressed. Likes requests now use a page size of 25. This reduces the
response size after pages of 50 felt slower to load, while still requesting more
tracks than the original 10. Subsequent pages use the API's `next_href` URL.

## Other simplifications

### Consolidate artwork image creation

The loader caches bytes, while the thumbnail, backdrop, and full-size sheet each
construct their own `NSImage`. The sheet adds another byte-retention layer in
[`TrackDetailView.swift:252`](SoundClaude/SoundClaude/App/TrackDetailView.swift#L252).

A bounded cache of images at suitable display sizes could reduce repeated image
work and remove that extra sheet cache.

### Remove unused playback metadata

Only `PlaybackSource.url` is consumed. Its kind, codec, bitrate, and preview
fields make the
[`stream candidate selection`](SoundClaude/SoundClaude/Networking/SoundCloudClient.swift#L272)
more complex without affecting current behavior.

## Reliability issues to address alongside performance work

[`Token refresh`](SoundClaude/SoundClaude/Auth/AuthController.swift#L116)
needs a shared in-progress task. Concurrent calls can duplicate refresh requests.

[`Track selection`](SoundClaude/SoundClaude/App/AppModel.swift#L102)
needs cancellation plus a latest-request check. An older track request can finish
last and replace a newer selection.

## Suggested starting order

1. Narrow view observation.
2. Stop idle visualizer work.
3. Simplify the Metal upload.

For comparison measurements, use Release. The
[`Makefile defaults to Debug`](Makefile#L3).
