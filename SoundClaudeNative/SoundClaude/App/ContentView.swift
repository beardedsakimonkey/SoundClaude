import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var auth: AuthController
    @ObservedObject private var library: LibraryController
    @ObservedObject private var playback: PlaybackController
    @ObservedObject private var audioTap: AudioTapController

    init(model: AppModel) {
        self.model = model
        _auth = ObservedObject(wrappedValue: model.auth)
        _library = ObservedObject(wrappedValue: model.library)
        _playback = ObservedObject(wrappedValue: model.playback)
        _audioTap = ObservedObject(wrappedValue: model.audioTap)
    }

    var body: some View {
        VStack(spacing: 0) {
            MetalVisualizerView(
                spectrumBuffer: model.analyzer.spectrumBuffer
            )
            .frame(minHeight: 180, idealHeight: 240, maxHeight: 300)

            Divider()

            Group {
                switch auth.state {
                case .signedOut, .failed:
                    signedOutView
                case .restoring:
                    progressView(label: "Restoring SoundCloud session")
                case .signingIn:
                    progressView(label: "Waiting for SoundCloud sign-in")
                case let .signedIn(user):
                    libraryView(user: user)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            playerFooter
        }
        .frame(minWidth: 760, minHeight: 620)
        .task {
            await model.start()
        }
    }

    private var signedOutView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("SoundClaude")
                .font(.largeTitle.weight(.semibold))
            Text(authFailureMessage ?? model.errorMessage
                ?? "Sign in to load your liked tracks.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("Sign in with SoundCloud") {
                Task { await model.signIn() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(32)
    }

    private func progressView(label: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    private func libraryView(user: SoundCloudUser) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Liked tracks")
                        .font(.title2.weight(.semibold))
                    Text(user.username)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if library.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Reload") {
                    Task { await library.loadLikedTracks() }
                }
                Button("Sign out") {
                    Task { await model.signOut() }
                }
            }
            .padding()

            if let message = model.errorMessage ?? library.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                    Spacer()
                }
                .foregroundStyle(.orange)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            List(library.tracks) { track in
                Button {
                    Task { await model.play(track) }
                } label: {
                    HStack(spacing: 12) {
                        TrackArtworkView(
                            artworkURL: track.artworkURL,
                            loader: model.artworkLoader,
                            size: 44
                        )
                        .overlay(alignment: .bottomTrailing) {
                            if playback.currentTrack?.urn == track.urn {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(.orange, in: Circle())
                                    .padding(2)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                                .lineLimit(1)
                            Text(track.uploader)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(format(milliseconds: track.durationMilliseconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if library.tracks.isEmpty, !library.isLoading {
                    ContentUnavailableView(
                        "No liked tracks",
                        systemImage: "heart.slash"
                    )
                }
            }
        }
    }

    private var playerFooter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                TrackArtworkView(
                    artworkURL: playback.currentTrack?.artworkURL,
                    loader: model.artworkLoader,
                    size: 48
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.currentTrack?.title ?? "Select a track")
                        .font(.headline)
                        .lineLimit(1)
                    Text(playback.currentTrack?.uploader
                        ?? "Choose a track to start listening")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(audioTap.state.label)
                    .font(.caption)
                    .foregroundStyle(audioTapStateColor)
            }

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
                Button(action: playback.previous) {
                    Image(systemName: "backward.end.fill")
                }
                Button(action: playback.togglePlayPause) {
                    Image(systemName: playback.isPlaying
                        ? "pause.circle.fill"
                        : "play.circle.fill")
                        .font(.title)
                }
                .disabled(playback.currentTrack == nil || playback.isLoading)
                Button(action: playback.next) {
                    Image(systemName: "forward.end.fill")
                }
                Spacer()
                Button(action: playback.toggleMute) {
                    Image(systemName: playback.isMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill")
                }
                Slider(value: $playback.volume, in: 0...1)
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
        .padding(14)
    }

    private var authFailureMessage: String? {
        if case let .failed(message) = auth.state { return message }
        return nil
    }

    private var audioTapStateColor: Color {
        if case .failed = audioTap.state { return .red }
        return .secondary
    }

    private func format(milliseconds: Int) -> String {
        format(seconds: Double(milliseconds) / 1_000)
    }

    private func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TrackArtworkView: View {
    let artworkURL: URL?
    let loader: ArtworkLoader
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: artworkURL) {
            image = nil
            guard let artworkURL,
                  let data = try? await loader.data(for: artworkURL),
                  !Task.isCancelled else {
                return
            }
            image = NSImage(data: data)
        }
    }
}
