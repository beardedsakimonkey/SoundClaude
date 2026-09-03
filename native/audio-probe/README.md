# SoundClaude native audio probe

This macOS-only proof plays an HLS stream with `AVPlayer`, captures the PCM
output of its own process with a Core Audio process tap, and calculates a
64-bin FFT with Accelerate. It does not decode HLS itself. When the Tauri app
starts the proof, a loopback proxy sends all SoundCloud CDN requests through
Rust.

It requires macOS 14.2 or later. macOS asks for System Audio Recording
permission on first use.

Build it:

```sh
./native/audio-probe/build.sh
```

Send one JSON line to the executable. Keep signed URLs out of command-line
arguments because arguments are visible to other processes.

```sh
printf '%s\n' '{"url":"https://example.com/stream.m3u8"}' | \
  ./native/audio-probe/build/SoundClaudeAudioProbe.app/Contents/MacOS/SoundClaudeAudioProbe
```

Standard output is newline-delimited JSON. Spectrum messages have this shape:

```json
{"type":"spectrum","time":42.0,"rms":0.12,"bins":[0.1,0.2]}
```

The proof uses a short lock in its audio callback. Before this becomes the
production playback path, replace that store with a lock-free ring buffer and
send the FFT frames to the Tauri webview over events or shared memory.

The Rust bridge exposes `start_native_audio_probe` and
`stop_native_audio_probe`. It emits status, format, error, and spectrum payloads
on the `native-audio-probe` Tauri event.
