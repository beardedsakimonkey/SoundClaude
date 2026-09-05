import AppKit
import SwiftUI

struct PlayerFooterView: View {
    let artworkLoader: ArtworkLoader
    let onSelectTrack: (SoundCloudTrack) -> Void

    @State private var artworkTrack: SoundCloudTrack?
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?
    @State private var isHoveringTitle = false
    @State private var artworkAccent: ArtworkAccent?
    @State private var accentArtworkURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @Bindable private var playback: PlaybackController

    init(
        playback: PlaybackController,
        artworkLoader: ArtworkLoader,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void
    ) {
        self.artworkLoader = artworkLoader
        self.onSelectTrack = onSelectTrack
        self.playback = playback
    }

    var body: some View {
        HStack(spacing: 20) {
            trackIdentity
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 280)
            playbackControls
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
        }
        .padding(14)
        .background {
            TrackArtworkBackdropView(
                artworkURL: playback.currentTrack?.artworkURL,
                loader: artworkLoader,
                fadesToBottom: false
            )
            .mask {
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
            }
        }
        .sheet(item: $artworkTrack) { track in
            FullSizeArtworkView(
                title: track.title,
                artworkURL: track.artworkURL,
                loader: artworkLoader,
                cachedArtwork: $cachedFullSizeArtwork
            )
        }
        .task(id: playback.currentTrack?.artworkURL) {
            artworkAccent = nil
            accentArtworkURL = nil
            guard let url = playback.currentTrack?.artworkURL,
                  let accent = try? await artworkLoader.accentColor(for: url),
                  !Task.isCancelled else { return }
            artworkAccent = accent
            accentArtworkURL = url
        }
    }

    private var trackIdentity: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                if let track = playback.currentTrack {
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text(track.title)
                            .underline(isHoveringTitle)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringTitle = $0 }
                    .help(track.title)
                } else {
                    Text("Select a track")
                }
                Text(playback.currentTrack?.uploader
                    ?? "Choose a track to start listening")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.headline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let track = playback.currentTrack, track.artworkURL != nil {
            Button {
                artworkTrack = track
            } label: {
                artworkThumbnail
            }
            .buttonStyle(.plain)
            .help("View full-size artwork")
            .accessibilityLabel("View full-size artwork for \(track.title)")
        } else {
            artworkThumbnail
        }
    }

    private var artworkThumbnail: some View {
        TrackArtworkView(
            artworkURL: playback.currentTrack?.artworkURL,
            loader: artworkLoader,
            size: 80,
            rendition: .square500
        )
    }

    private var playbackControls: some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 1)
            )

            HStack(spacing: 16) {
                Text(format(seconds: playback.currentTime))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .leading)
                Spacer()
                transportControls
                Spacer()
                Button(action: playback.toggleMute) {
                    Image(systemName: playback.isMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill")
                }
                ArtworkVolumeSlider(
                    value: $playback.volume,
                    accent: volumeAccent,
                    trackColor: ArtworkAccent.trackBackground(isDark: colorScheme == .dark)
                )
                    .frame(width: 110)
                Text(format(seconds: playback.duration))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }
            .buttonStyle(.borderless)

            if let playbackError = playback.errorMessage {
                Text(playbackError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var volumeAccent: ArtworkAccent {
        let blue = NSColor.systemBlue.usingColorSpace(.sRGB)!
        let fallback = ArtworkAccent(
            red: blue.redComponent, green: blue.greenComponent, blue: blue.blueComponent
        )
        let accent = accentArtworkURL == playback.currentTrack?.artworkURL
            ? artworkAccent ?? fallback : fallback
        return accent.contrasted(
            isDark: colorScheme == .dark,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private var transportControls: some View {
        Group {
            if #available(macOS 26.0, *) {
                transportButtons
                    .buttonStyle(.glass(.clear))
            } else {
                transportButtons
                    .buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private var transportButtons: some View {
        HStack(spacing: 12) {
            Button(action: playback.previous) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .help("Previous track")
            .accessibilityLabel("Previous track")

            Button(action: playback.togglePlayPause) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(playback.currentTrack == nil || playback.isLoading)
            .help(playback.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button(action: playback.next) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .help("Next track")
            .accessibilityLabel("Next track")
        }
    }

    private func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// Keep native keyboard, focus, and accessibility behavior while drawing the bar
// explicitly: macOS slider tint behavior varies with the OS and accent settings.
private struct ArtworkVolumeSlider: NSViewRepresentable {
    @Binding var value: Float
    let accent: ArtworkAccent
    let trackColor: ArtworkAccent

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 1,
                              target: context.coordinator,
                              action: #selector(Coordinator.changed(_:)))
        slider.cell = ArtworkVolumeSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("Volume")
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.doubleValue = Double(value)
        slider.setAccessibilityValueDescription("\(Int(value * 100)) percent")
        if let cell = slider.cell as? ArtworkVolumeSliderCell {
            cell.accent = NSColor(srgbRed: accent.red, green: accent.green,
                                  blue: accent.blue, alpha: 1)
            cell.trackColor = NSColor(srgbRed: trackColor.red, green: trackColor.green,
                                      blue: trackColor.blue, alpha: 1)
        }
        slider.needsDisplay = true
    }

    final class Coordinator: NSObject {
        var value: Binding<Float>
        init(value: Binding<Float>) { self.value = value }

        @objc func changed(_ sender: NSSlider) {
            value.wrappedValue = sender.floatValue
        }
    }
}

private final class ArtworkVolumeSliderCell: NSSliderCell {
    var accent = NSColor.systemBlue
    var trackColor = NSColor.controlBackgroundColor

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 3, width: rect.width, height: 6)
        let path = NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3)
        trackColor.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        accent.setFill()
        let fraction = CGFloat((doubleValue - minValue) / (maxValue - minValue))
        NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
