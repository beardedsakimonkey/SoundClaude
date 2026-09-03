# Native macOS migration handoff

This document is the technical handoff for migrating SoundClaude from Tauri,
React, and Rust to a native macOS app.

The project owner has explicitly removed the old rule that all SoundCloud API
and CDN requests must go through Rust. In the native app, Swift can make these
requests directly with `URLSession`.

## Why migrate

The web version can play SoundCloud HLS, but Safari/WebKit does not provide
useful PCM data from this media path to the Web Audio analyser. The analyser
returned zero data. This prevents a reliable, smooth FFT-driven visualizer.

A native proof now works:

1. `AVPlayer` plays the SoundCloud HLS stream.
2. A Core Audio process tap captures the audio produced by that player process.
3. Accelerate/vDSP converts the PCM into FFT bands.
4. The visualizer receives nonzero, moving spectrum data.

This uses Apple's HLS and AAC decoding. The app does not need to implement a
media decoder.

The proof still sends spectrum data through a helper process, temporary output,
Rust, Tauri events, React, and WebGL. That transport adds latency and jitter. A
single native process can remove those stages and render directly with Metal.

## Target data flow

```text
SoundCloud API and CDN
        |
        v
Swift URLSession -> AVPlayer -> Apple HLS/AAC decoder -> system audio output
                         |
                         v
              Core Audio process tap
                         |
                         v
             lock-free PCM ring buffer
                         |
                         v
             Accelerate/vDSP FFT worker
                         |
                         v
              latest spectrum snapshot
                         |
                         v
                 MTKView + Metal
```

The new app does not need the Rust loopback proxy, native helper process, file
polling, Tauri event bridge, React, WebGL, or a webview.

## Recommended app architecture

Use SwiftUI for the application shell and normal controls. Do not send audio or
render-frame data through SwiftUI observation.

- `PlaybackController`: Owns `AVPlayer`, the selected track, queue, playback
  state, current time, seek, volume, mute, next, and previous actions. Keep UI
  changes on the main actor.
- `AudioTapController`: Creates and destroys the Core Audio process tap,
  aggregate device, and IO callback.
- `PCMRingBuffer`: A fixed-capacity, lock-free buffer between the real-time audio
  callback and the analysis worker. Implement the critical part in C, C++, or
  Objective-C++.
- `SpectrumAnalyzer`: Reads PCM from the ring buffer and computes FFT bands with
  Accelerate/vDSP. Publishes the latest spectrum through a fixed-size snapshot
  or double buffer.
- `MetalVisualizerView`: Wraps `MTKView`. Its renderer reads the latest spectrum
  snapshot directly and updates a small Metal buffer or 1D texture.
- `SoundCloudClient`: Uses `URLSession` for SoundCloud API and CDN requests.
- `AuthController`: Owns OAuth, token refresh, and Keychain storage.
- Library models and services: Load liked tracks and convert API data into app
  models.

A possible file layout is:

```text
SoundClaudeNative/
  SoundClaude.xcodeproj
  SoundClaude/
    App/SoundClaudeApp.swift
    Auth/AuthController.swift
    Networking/SoundCloudClient.swift
    Models/
    Library/
    Playback/PlaybackController.swift
    Audio/ProcessTap.swift
    Audio/PCMRingBuffer.h
    Audio/PCMRingBuffer.mm
    Audio/SpectrumAnalyzer.swift
    Visualizer/MetalVisualizerView.swift
    Visualizer/VisualizerRenderer.swift
    Shaders/AudioVisualizer.metal
    Resources/
```

Keep the first implementation in one app target unless module boundaries become
useful. Avoid creating many packages during the first migration stage.

## AVPlayer playback

Use one `AVPlayer` as the only audio output. This prevents the duplicate playback
that occurred while the browser player and native probe played at the same time.

For each selected track:

1. Resolve the preferred SoundCloud stream URL.
2. Create an `AVPlayerItem` from the URL.
3. Replace the current player item.
4. Observe `AVPlayerItem.status` and wait for `.readyToPlay`.
5. Start or reconfigure the process tap after the item is ready.
6. Call `play()` only on the native player.

`AVPlayer` performs HLS playlist handling, segment loading, decryption when
applicable, and AAC/MP3 decoding. Do not add FFmpeg or a custom decoder for this
design.

Do not use `MTAudioProcessingTap` through `AVPlayerItem.audioMix` for SoundCloud
HLS. It was tested and produced zero PCM when used without a file-backed asset
track. Apple's documentation also states that an audio mix is for file-based
media and is not supported for HTTP Live Streaming:

- [AVPlayerItem audioMix documentation](https://developer.apple.com/documentation/avfoundation/avplayeritem/audiomix)

## Core Audio process tap

Core Audio process taps are available on macOS 14.2 and later. They capture the
output of one or more audio processes after the media has been decoded. Limit the
tap to this application's audio process. Do not capture all system audio.

The working proof uses this sequence:

1. Start `AVPlayer` and wait until its item is ready.
2. Translate the app PID to an Audio Hardware `AudioProcess` object. Query the
   system object with `kAudioHardwarePropertyTranslatePIDToProcessObject` and use
   the current `pid_t` as the qualifier.
3. Create a `CATapDescription` for that process object.
   - Set `processes` to the app's AudioProcess object ID.
   - Set `isPrivate` to `true`.
   - Set `isMixdown` to `true`.
   - Set `isMono` to `false`.
   - Set `isExclusive` to `false`.
   - Set `muteBehavior` to `.unmuted` so capture does not silence playback.
4. Call `AudioHardwareCreateProcessTap`.
5. Read the new tap UID with `kAudioTapPropertyUID`.
6. Create a private aggregate device with
   `AudioHardwareCreateAggregateDevice`. Give it a unique name and UID. Set
   `kAudioAggregateDeviceIsPrivateKey` and
   `kAudioAggregateDeviceTapAutoStartKey` to `true`.
7. Attach the tap UID to the aggregate through
   `kAudioAggregateDevicePropertyTapList`.
8. Wait until the aggregate exposes its input stream. Device configuration can
   be asynchronous.
9. Read the tap's `AudioStreamBasicDescription` through
   `kAudioTapPropertyFormat`.
10. Register an IO callback and start the aggregate device. The proof uses
    `AudioDeviceCreateIOProcIDWithBlock` and `AudioDeviceStart`.
11. Read the Float32 buffers in the callback and downmix channels to mono for
    analysis.
12. On stop or track reconfiguration, tear resources down in reverse order:
    stop the device, destroy the IO proc, destroy the aggregate device, and
    destroy the process tap.

The proof observed 48 kHz, stereo, Float32 audio. Always inspect the returned
ASBD. Do not hard-code this format.

Apple's reference sample is the primary implementation guide:

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

### Real-time safety

The current proof uses `NSLock` and copies Swift arrays in the IO callback. This
is acceptable only for a prototype. Apple's sample notes that Swift does not
give the required real-time guarantees for an AudioDevice IO callback and puts
that callback in Objective-C++.

Production callback rules:

- Allocate all storage before the callback starts.
- Do not acquire locks.
- Do not allocate or resize arrays.
- Do not create JSON.
- Do not log.
- Do not dispatch SwiftUI state changes.
- Copy or write samples only into a fixed-capacity lock-free ring buffer.
- Handle format and device changes outside the callback.

Use atomics for producer and consumer indices. The audio callback is the single
producer. The FFT worker is the single consumer.

## Audio capture permission

Add `NSAudioCaptureUsageDescription` to the app's `Info.plist`. macOS will ask
the user for System Audio Recording permission.

The app must run as a real signed or development `.app` bundle with a stable
bundle identifier. Do not run only a loose executable from Terminal during
permission testing. If capture remains silent:

1. Check System Settings > Privacy & Security > Screen & System Audio Recording.
2. Confirm that the native app has permission.
3. Quit and reopen the app after a permission change.
4. Recreate the process tap after permission is granted.
5. Show a clear UI state for denied or missing permission.

The current Tauri proof had to launch its helper with Launch Services by using
`/usr/bin/open -n -g -W` so macOS identified the helper bundle correctly. This
workaround is not needed when playback and capture live in the main native app.

## FFT and spectrum updates

The proof configuration is:

- PCM ring capacity: 8,192 samples.
- FFT window: 2,048 samples.
- Hann window.
- Accelerate functions: `vDSP_create_fftsetup`, `vDSP_fft_zrip`, and
  `vDSP_zvmags`.
- Output: 64 log-spaced bands from approximately 30 Hz to 18 kHz.
- Magnitudes converted to dB and normalized for the shader.

Keep the audio, analysis, and display rates independent:

- The audio callback writes PCM continuously.
- An analysis worker runs when a new hop is available. A 512-sample hop at
  48 kHz gives about 93.75 spectrum updates per second. A 1,024-sample hop gives
  about 46.9 updates per second.
- `MTKView` renders at the display cadence, normally 60 or 120 frames per
  second.
- The renderer interpolates or smooths between spectrum snapshots.

Use attack and release smoothing instead of a single slow low-pass value. A
fast attack and slower release usually gives responsive motion without flicker.
Do not publish 60 to 120 SwiftUI observable changes per second.

## Metal visualizer

Use `MTKView` and `MTKViewDelegate` for stable frame pacing. Set
`preferredFramesPerSecond` to a rate supported by the display. If practical,
use the display link cadence instead of a general-purpose timer.

Pass 64 or 128 floats to Metal with either:

- a small shared `MTLBuffer`, or
- a small one-dimensional float texture.

The renderer should update this resource once per draw from the latest spectrum
snapshot. The fragment shader can sample the bands and add time-based movement,
but the visible amplitude must come from real FFT data. Keep the visualizer in a
bounded view above the main content and leave the footer visible.

Record frame time during development. The first acceptance target is stable
60 fps. On 120 Hz displays, support 120 fps if GPU cost and power use are
reasonable.

## SoundCloud API and authentication

The authoritative API description remains [`api.yaml`](../api.yaml).

The native client can make SoundCloud API and CDN requests directly. Use
`URLSession` and store access and refresh tokens in Keychain. Do not put tokens,
signed CDN URLs, or client secrets in logs or process arguments.

Current endpoints and behavior to port:

- Authorization: `https://secure.soundcloud.com/authorize`
- Token exchange and refresh: `https://secure.soundcloud.com/oauth/token`
- Sign out: `https://secure.soundcloud.com/sign-out`
- API base: `https://api.soundcloud.com/`
- API authorization header: `Authorization: OAuth <access-token>`
- Current user: `GET /me`
- Liked tracks:
  `GET /me/likes/tracks?limit=100&linked_partitioning=true&access=playable,preview`
- Streams: `GET /tracks/{track_urn}/streams`, with `secret_token` when required.
- Preferred stream order: `hls_aac_160_url`, `hls_mp3_128_url`, then
  `preview_mp3_128_url`.

Preserve private-track tokens supplied by `secret_uri`. Refresh OAuth tokens
before expiry; the current implementation uses a 60-second safety margin.

The stream endpoint can redirect. Follow its authenticated response, then
validate the final HTTPS host before playback. The current accepted hosts are:

- `sndcdn.com` and its subdomains.
- `playback.media-streaming.soundcloud.cloud`.

OAuth currently uses PKCE S256 and a random state value. The registered callback
is `http://127.0.0.1:32148/callback`. A native app can keep it with a short-lived
local `NWListener`. A custom URL scheme is simpler only if the SoundCloud app
registration supports it and is updated first. `ASWebAuthenticationSession` is
the preferred browser authentication UI where it fits the registered callback.

The current personal app embeds SoundCloud application credentials. Before
distribution, decide how to manage the client secret. A public desktop binary
cannot keep an embedded secret confidential. A small service or credential
rotation plan can be required for a distributed app.

## Current feature parity target

Do not remove the old app until the native app has these features:

- OAuth sign in and sign out.
- Token refresh and Keychain persistence.
- Liked-track list, artwork, and waveform metadata.
- Track playback and queue selection.
- Seek, mute, and volume controls.
- Previous and next track actions.
- A waveform or playback timeline in the footer.
- A live FFT-driven Metal visualizer.
- Light and dark appearance.
- Keyboard commands:
  - Space: play or pause.
  - M: toggle mute.
  - Left and Right: seek backward or forward by 5 seconds.
  - Shift-Left and Shift-Right: previous or next track.
  - `?`: show the keyboard-shortcuts dialog.
  - Escape: close the dialog.

Later, add `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` for media keys,
Control Center, and Now Playing integration.

## Suggested migration stages

### Stage 0: Add the native target

Create a macOS SwiftUI Xcode project beside the existing Tauri source. Set the
deployment target to macOS 14.2 or later. Add the audio-capture usage string and
the required app capabilities. Keep the old application buildable.

### Stage 1: Port data and authentication

Implement API models, `SoundCloudClient`, OAuth PKCE, Keychain token storage,
refresh, and the liked-track list. Confirm pagination and private tracks.

### Stage 2: Port playback and controls

Implement one `AVPlayer`, queue changes, seeking, mute, volume, time observation,
and keyboard commands. Confirm that only one audio source plays.

### Stage 3: Make capture production-safe

Port the proven process-tap sequence. Replace prototype locks and allocations
with the fixed lock-free PCM ring. First show diagnostic RMS and spectrum values
before connecting the visual design.

### Stage 4: Add Metal rendering

Add `MTKView`, the visualizer renderer, a small spectrum buffer or texture, and
the fragment shader. Measure frame cadence and CPU/GPU use. Tune FFT hop size and
attack/release smoothing separately from render frequency.

### Stage 5: Reach UI parity

Port artwork, footer, waveform, shortcuts dialog, appearance, error states, and
permission recovery. Add native Now Playing integration if desired. Remove the
Tauri app only after explicit acceptance.

## Acceptance criteria

- The app uses `AVPlayer`; it contains no custom HLS or AAC decoder.
- SoundCloud HLS playback works for normal, preview, and private tracks that the
  account can access.
- PCM, RMS, and FFT values are nonzero and move during playback across multiple
  tracks.
- The process tap captures only this app and does not mute output.
- The real-time audio callback allocates no memory, takes no lock, and performs
  no logging or UI work.
- Metal rendering stays close to the selected 60 or 120 fps cadence without
  high-rate SwiftUI state updates.
- Playback controls do not create a second simultaneous player.
- Permission denial, permission approval, and relaunch are handled clearly.
- Access tokens, client secrets, and signed CDN URLs do not appear in logs or
  command-line arguments.
- OAuth state, PKCE, refresh, pagination, and token expiry behavior are tested
  against the current SoundCloud account.

## Existing proof files

Use these files as a behavioral reference. Do not copy their prototype transport
or real-time safety compromises into the final design.

- `native/audio-probe/Sources/main.swift`: `AVPlayer`, process tap, PCM, and FFT
  proof.
- `native/audio-probe/build.sh`: helper build script.
- `native/audio-probe/Info.plist`: permission declaration and bundle metadata.
- `native/audio-probe/AudioProbe.entitlements`: current helper entitlements.
- `src-tauri/src/native_probe.rs`: helper launch and spectrum transport.
- `src-tauri/src/soundcloud.rs`: current OAuth, API, stream selection, redirect,
  and host-validation behavior.
- `src/components/AudioVisualizer.tsx` and `src/shaders/`: current visual design
  reference.

The proof established the important result: Apple can decode the SoundCloud HLS
stream with `AVPlayer`, and a Core Audio process tap can provide live PCM for an
FFT. The migration should preserve that path and remove the cross-process and
webview transport around it.
