import AppKit
import Foundation
import SwiftUI

struct TrackDetailView: View {
    let track: SoundCloudTrack
    let model: AppModel

    @State private var details: SoundCloudTrackDetails?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isShowingArtwork = false
    @State private var isHoveringArtwork = false

    init(track: SoundCloudTrack, model: AppModel) {
        self.track = track
        self.model = model

        let cachedDetails = model.cachedTrackDetails(for: track)
        _details = State(initialValue: cachedDetails)
        _isLoading = State(initialValue: cachedDetails == nil)
    }

    var body: some View {
        ZStack(alignment: .top) {
            TrackArtworkBackdropView(
                artworkURL: details?.track.artworkURL ?? track.artworkURL,
                loader: model.artworkLoader
            )
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
                loader: model.artworkLoader
            )
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
                        Text(details.track.uploader)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        if let genre = nonempty(details.genre) {
                            Label(genre, systemImage: "music.note.list")
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await model.play(details.track) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
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

                Divider()

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 20,
                    verticalSpacing: 10
                ) {
                    informationRow(
                        "Duration",
                        value: format(
                            milliseconds: details.track.durationMilliseconds
                        )
                    )
                    informationRow("Uploaded", value: details.createdAt)
                    informationRow("Genre", value: details.genre)
                    informationRow(
                        "Access",
                        value: details.track.access.rawValue.capitalized
                    )
                }

                if let description = nonempty(details.description) {
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
                    .overlay(alignment: .bottomTrailing) {
                        if isHoveringArtwork {
                            Image(
                                systemName: "arrow.up.left.and.arrow.down.right"
                            )
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(
                                    .black.opacity(0.65),
                                    in: Circle()
                                )
                                .padding(7)
                                .transition(.opacity)
                        }
                    }
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHoveringArtwork = $0 }
            .animation(
                .easeInOut(duration: 0.12),
                value: isHoveringArtwork
            )
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
            size: 180
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    .white.opacity(0.2),
                    lineWidth: 1
                )
        }
    }

    @ViewBuilder
    private func statistic(_ count: Int?, label: String) -> some View {
        if let count {
            Text("\(count.formatted()) \(label)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func informationRow(_ label: String, value: String?) -> some View {
        if let value = nonempty(value) {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
            }
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func format(milliseconds: Int) -> String {
        let totalSeconds = max(milliseconds, 0) / 1_000
        return String(
            format: "%d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
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

private struct FullSizeArtworkView: View {
    let title: String
    let artworkURL: URL?
    let loader: ArtworkLoader

    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        let displaySize = artworkDisplaySize

        ZStack(alignment: .topTrailing) {
            Group {
                Color.black

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .accessibilityLabel("Artwork for \(title)")
                } else if isLoading {
                    ProgressView("Loading artwork")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else {
                    ContentUnavailableView {
                        Label(
                            "Could not load artwork",
                            systemImage: "photo.badge.exclamationmark"
                        )
                    } description: {
                        Text(errorMessage ?? "An unknown error occurred.")
                    } actions: {
                        Button("Try Again") {
                            Task { await load() }
                        }
                    }
                    .foregroundStyle(.white)
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.65), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close artwork")
            .padding(12)
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .task(id: artworkURL) {
            await load()
        }
    }

    private var artworkDisplaySize: CGSize {
        guard let image,
              image.size.width > 0,
              image.size.height > 0 else {
            return CGSize(width: 480, height: 480)
        }

        let maximumDimension: CGFloat = 640
        let scale = maximumDimension
            / max(image.size.width, image.size.height)
        return CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
    }

    private func load() async {
        image = nil
        isLoading = true
        errorMessage = nil

        guard let artworkURL else {
            isLoading = false
            errorMessage = "This track does not have artwork."
            return
        }

        do {
            let data = try await loader.data(
                for: artworkURL,
                rendition: .original
            )
            guard let loadedImage = NSImage(data: data) else {
                throw ArtworkLoadError.invalidImage
            }
            image = loadedImage
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private enum ArtworkLoadError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The artwork data is not a valid image."
    }
}

private struct TrackArtworkBackdropView: View {
    let artworkURL: URL?
    let loader: ArtworkLoader

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .scaleEffect(1.15)
                    .blur(radius: 36)
                    .saturation(1.15)
                    .opacity(0.38)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.75), location: 0.6),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
        }
        .frame(height: 340)
        .clipped()
        .allowsHitTesting(false)
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
