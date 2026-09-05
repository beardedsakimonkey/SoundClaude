import AppKit
import Foundation
import SwiftUI

struct TrackDetailView: View {
    let track: SoundCloudTrack
    let model: AppModel
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var details: SoundCloudTrackDetails?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isShowingArtwork = false
    @State private var isHoveringArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

    init(
        track: SoundCloudTrack,
        model: AppModel,
        onSelectArtist: @escaping (SoundCloudUser) -> Void
    ) {
        self.track = track
        self.model = model
        self.onSelectArtist = onSelectArtist

        let cachedDetails = model.cachedTrackDetails(for: track)
        _details = State(initialValue: cachedDetails)
        _isLoading = State(initialValue: cachedDetails == nil)
    }

    var body: some View {
        ZStack(alignment: .top) {
            artworkBackdrop
                .ignoresSafeArea(edges: .top)

            Group {
                if let details {
                    detailsView(details)
                } else if isLoading {
                    ProgressView("Loading track")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(
                            "Could not load track",
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(errorMessage ?? "An unknown error occurred.")
                    } actions: {
                        Button("Try Again") {
                            Task { await load() }
                        }
                    }
                }
            }
        }
        .navigationTitle(details?.track.title ?? track.title)
        .task(id: track.urn) {
            await load()
        }
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: details?.track.title ?? track.title,
                artworkURL: details?.track.artworkURL ?? track.artworkURL,
                loader: model.artworkLoader,
                cachedArtwork: $cachedFullSizeArtwork
            )
        }
    }

    @ViewBuilder
    private var artworkBackdrop: some View {
        let backdrop = TrackArtworkBackdropView(
            artworkURL: details?.track.artworkURL ?? track.artworkURL,
            loader: model.artworkLoader
        )
        .frame(height: 340)

        if #available(macOS 26.0, *) {
            backdrop.backgroundExtensionEffect()
        } else {
            backdrop
        }
    }

    private func detailsView(_ details: SoundCloudTrackDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    artworkView(for: details.track)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(details.track.title)
                            .font(.largeTitle.weight(.semibold))
                            .textSelection(.enabled)
                        ArtistLink(artist: details.track.artist, onSelect: onSelectArtist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            playButton(for: details.track)
                            Link(destination: details.track.permalinkURL) {
                                Label("Open in SoundCloud", systemImage: "arrow.up.right.square")
                            }
                            .help("Open this track in your web browser")
                        }
                    }
                }

                HStack(spacing: 24) {
                    statistic(details.playbackCount, label: "plays")
                    statistic(details.favoritingsCount, label: "likes")
                    statistic(details.commentCount, label: "comments")
                }

                if details.track.waveformURL != nil {
                    TrackWaveformView(track: details.track, model: model)
                }

                if let description = nonempty(details.description) {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.headline)
                        Text(description)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    @ViewBuilder
    private func artworkView(for track: SoundCloudTrack) -> some View {
        if track.artworkURL != nil {
            Button {
                isShowingArtwork = true
            } label: {
                artworkThumbnail(for: track)
                    .artworkExpandIndicator(isHovering: isHoveringArtwork)
            }
            .buttonStyle(DetailArtworkButtonStyle(isHovering: isHoveringArtwork))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHoveringArtwork = $0 }
            .help("View full-size artwork")
            .accessibilityLabel(
                "View full-size artwork for \(track.title)"
            )
        } else {
            artworkThumbnail(for: track)
        }
    }

    private func artworkThumbnail(for track: SoundCloudTrack) -> some View {
        TrackArtworkView(
            artworkURL: track.artworkURL,
            loader: model.artworkLoader,
            size: 180,
            rendition: .square500
        )
    }

    @ViewBuilder
    private func statistic(_ count: Int?, label: String) -> some View {
        if let count {
            Text("\(count.formatted()) \(label)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func playButton(for track: SoundCloudTrack) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                playButtonLabel(for: track)
                    .buttonStyle(SpringGlassButtonStyle())
            } else {
                playButtonLabel(for: track)
                    .buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private func playButtonLabel(for track: SoundCloudTrack) -> some View {
        let playback = model.playback
        let isCurrentTrack = playback.currentTrack?.urn == track.urn
        let isPlaying = isCurrentTrack && playback.isPlaying

        return Button {
            if playback.currentTrack?.urn == track.urn {
                playback.togglePlayPause()
            } else {
                Task { await model.play(track) }
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func load() async {
        if let cachedDetails = model.cachedTrackDetails(for: track) {
            details = cachedDetails
            isLoading = false
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            details = try await model.trackDetails(for: track)
        } catch {
            details = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct DetailArtworkButtonStyle: ButtonStyle {
    let isHovering: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let scale: CGFloat = reduceMotion ? 1
            : configuration.isPressed ? 1 : isHovering ? 1.04 : 1

        configuration.label
            .scaleEffect(scale)
            .animation(
                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6),
                value: scale
            )
    }
}
