import Foundation
import SwiftUI

struct LibraryView: View {
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let appErrorMessage: String?
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void
    let onSignOut: () async -> Void

    @ObservedObject private var library: LibraryController
    @ObservedObject private var playback: PlaybackController
    @State private var hoveredTrackURN: String?
    @State private var hoveredTitleURN: String?

    init(
        user: SoundCloudUser,
        library: LibraryController,
        playback: PlaybackController,
        artworkLoader: ArtworkLoader,
        appErrorMessage: String?,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onPlayTrack: @escaping (SoundCloudTrack) async -> Void,
        onSignOut: @escaping () async -> Void
    ) {
        self.user = user
        self.artworkLoader = artworkLoader
        self.appErrorMessage = appErrorMessage
        self.onSelectTrack = onSelectTrack
        self.onPlayTrack = onPlayTrack
        self.onSignOut = onSignOut
        _library = ObservedObject(wrappedValue: library)
        _playback = ObservedObject(wrappedValue: playback)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            errorBanner
            trackList
        }
    }

    private var header: some View {
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
            Button("Sign out") {
                Task { await onSignOut() }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = appErrorMessage ?? library.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                Spacer()
            }
            .foregroundStyle(.orange)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var trackList: some View {
        List(library.tracks) { track in
            HStack(spacing: 12) {
                artwork(for: track)
                trackIdentity(for: track)
                Spacer()
                Text(format(milliseconds: track.durationMilliseconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard hoveredTitleURN != track.urn else { return }
                Task { await onPlayTrack(track) }
            }
            .listRowBackground(
                hoveredTrackURN == track.urn
                    ? Color.primary.opacity(0.06)
                    : Color.clear
            )
            .onHover { isHovering in
                if isHovering {
                    hoveredTrackURN = track.urn
                } else if hoveredTrackURN == track.urn {
                    hoveredTrackURN = nil
                }
            }
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

    private func artwork(for track: SoundCloudTrack) -> some View {
        TrackArtworkView(
            artworkURL: track.artworkURL,
            loader: artworkLoader,
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
    }

    private func trackIdentity(for track: SoundCloudTrack) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                onSelectTrack(track)
            } label: {
                Text(track.title)
                    .underline(hoveredTitleURN == track.urn)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .lineLimit(1)
            .onHover { isHovering in
                if isHovering {
                    hoveredTitleURN = track.urn
                } else if hoveredTitleURN == track.urn {
                    hoveredTitleURN = nil
                }
            }
            Text(track.uploader)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func format(milliseconds: Int) -> String {
        let totalSeconds = max(milliseconds, 0) / 1_000
        return String(
            format: "%d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }
}
