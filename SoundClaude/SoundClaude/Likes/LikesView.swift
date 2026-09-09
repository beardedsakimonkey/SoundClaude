import Foundation
import SwiftUI

struct LikesView: View {
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let spectrumBuffer: OpaquePointer
    let appErrorMessage: String?
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @ObservedObject private var likes: LikesController
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    private let playback: PlaybackController

    init(
        user: SoundCloudUser,
        likes: LikesController,
        playback: PlaybackController,
        artworkLoader: ArtworkLoader,
        spectrumBuffer: OpaquePointer,
        appErrorMessage: String?,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onPlayTrack: @escaping (SoundCloudTrack) async -> Void
    ) {
        self.user = user
        self.artworkLoader = artworkLoader
        self.spectrumBuffer = spectrumBuffer
        self.appErrorMessage = appErrorMessage
        self.onSelectArtist = onSelectArtist
        self.onSelectTrack = onSelectTrack
        self.onPlayTrack = onPlayTrack
        _likes = ObservedObject(wrappedValue: likes)
        self.playback = playback
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ArtworkVisualizerView(
                    spectrumBuffer: spectrumBuffer,
                    artworkURL: playback.currentTrack?.artworkURL,
                    artworkLoader: artworkLoader
                )
                    .frame(height: 120)
                Divider()
                header
                errorBanner
                trackList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await likes.loadLikedTracks() }
    }

    private var header: some View {
        HStack {
            Text("Likes")
                .font(.largeTitle.weight(.semibold))
            Text("(\(likes.tracks.count))")
                .font(.largeTitle.weight(.regular))
                .foregroundStyle(.secondary)
            Spacer()
            if likes.isLoading {
                Text("Syncing likes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
            }
            searchBar
                .frame(maxWidth: 280)
        }
        .padding()
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onExitCommand {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchText = ""
                    }
                    isSearchFocused = false
                }
                .accessibilityLabel("Search liked tracks")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .background {
            SearchOutsideClickView(isFocused: isSearchFocused) {
                if isSearchFocused {
                    isSearchFocused = false
                }
            }
        }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredTracks: [SoundCloudTrack] {
        let query = searchQuery
        guard !query.isEmpty else { return likes.tracks }
        return likes.tracks.filter {
            $0.title.localizedStandardContains(query)
                || $0.artist.username.localizedStandardContains(query)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = appErrorMessage ?? likes.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                Spacer()
                if likes.errorMessage != nil {
                    Button("Try again") { Task { await likes.loadLikedTracks() } }
                        .disabled(likes.isLoading)
                }
            }
            .foregroundStyle(.orange)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if likes.tracks.isEmpty,
           !likes.isLoading,
           !likes.canLoadMore {
            ContentUnavailableView(
                "No liked tracks",
                systemImage: "heart.slash"
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            let tracks = filteredTracks
            LazyVStack(alignment: .leading, spacing: 0) {
                if tracks.isEmpty, !searchQuery.isEmpty {
                    ContentUnavailableView(
                        "No matching tracks",
                        systemImage: "magnifyingglass",
                        description: Text("No loaded liked tracks match your search.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }

                ForEach(tracks) { track in
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
    }

}
