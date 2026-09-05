import Foundation
import SwiftUI

struct LikesView: View {
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let appErrorMessage: String?
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void
    let onSignOut: () async -> Void

    @ObservedObject private var likes: LikesController
    private let playback: PlaybackController

    init(
        user: SoundCloudUser,
        likes: LikesController,
        playback: PlaybackController,
        artworkLoader: ArtworkLoader,
        appErrorMessage: String?,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onPlayTrack: @escaping (SoundCloudTrack) async -> Void,
        onSignOut: @escaping () async -> Void
    ) {
        self.user = user
        self.artworkLoader = artworkLoader
        self.appErrorMessage = appErrorMessage
        self.onSelectArtist = onSelectArtist
        self.onSelectTrack = onSelectTrack
        self.onPlayTrack = onPlayTrack
        self.onSignOut = onSignOut
        _likes = ObservedObject(wrappedValue: likes)
        self.playback = playback
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
            if likes.isLoading {
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
        if let message = appErrorMessage ?? likes.errorMessage {
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(likes.tracks) { track in
                    TrackListRow(
                        track: track,
                        playback: playback,
                        artworkLoader: artworkLoader,
                        onSelectTrack: onSelectTrack,
                        onSelectArtist: onSelectArtist,
                        onPlayTrack: onPlayTrack
                    )
                }

                if likes.canLoadMore {
                    paginationRow
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if likes.tracks.isEmpty,
               !likes.isLoading,
               !likes.canLoadMore {
                ContentUnavailableView(
                    "No liked tracks",
                    systemImage: "heart.slash"
                )
            }
        }
    }

    private var paginationRow: some View {
        HStack {
            Spacer()
            if likes.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(likes.errorMessage == nil ? "Load more" : "Try again") {
                    Task { await likes.loadMore() }
                }
            }
            Spacer()
        }
        .onAppear {
            guard likes.errorMessage == nil else { return }
            Task { await likes.loadMore() }
        }
    }

}
