import Foundation
import SwiftUI

struct LikesView: View {
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let appErrorMessage: String?
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onAddToQueue: (SoundCloudTrack) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @ObservedObject private var likes: LikesController
    @State private var searchText = ""
    @AppStorage("likesTrackLayout") private var trackLayout = TrackLayout.list
    @FocusState private var isSearchFocused: Bool
    private let playback: PlaybackController
    private let analyzer: SpectrumAnalyzer

    init(
        user: SoundCloudUser,
        likes: LikesController,
        playback: PlaybackController,
        analyzer: SpectrumAnalyzer,
        artworkLoader: ArtworkLoader,
        appErrorMessage: String?,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onAddToQueue: @escaping (SoundCloudTrack) -> Void,
        onPlayTrack: @escaping (SoundCloudTrack) async -> Void
    ) {
        self.user = user
        self.artworkLoader = artworkLoader
        self.appErrorMessage = appErrorMessage
        self.onSelectArtist = onSelectArtist
        self.onSelectTrack = onSelectTrack
        self.onAddToQueue = onAddToQueue
        self.onPlayTrack = onPlayTrack
        _likes = ObservedObject(wrappedValue: likes)
        self.playback = playback
        self.analyzer = analyzer
    }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            ScrollView {
                VStack(spacing: 0) {
                    header
                    errorBanner
                    trackList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await likes.loadLikedTracks() }
    }

    @ViewBuilder
    private var backdrop: some View {
        let gradient = LinearGradient(
            colors: [.orange.opacity(0.3), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 150)

        if #available(macOS 26.0, *) {
            gradient.backgroundExtensionEffect()
        } else {
            gradient
        }
    }

    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline) {
                Text("Likes")
                    .font(.largeTitle.weight(.semibold))
                Text("(\(likes.tracks.count))")
                    .font(.title.weight(.regular))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if likes.isLoading {
                ProgressView()
                    .accessibilityLabel("Syncing likes")
                    .controlSize(.small)
            }
            TrackLayoutPicker(trackLayout: $trackLayout)
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
                .modifier(PreventAutomaticSearchFocus())
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

                if trackLayout == .grid {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), spacing: 20, alignment: .top)],
                        alignment: .leading,
                        spacing: 24
                    ) {
                        ForEach(tracks) { track in
                            TrackGridTile(
                                track: track,
                                playback: playback,
                                analyzer: analyzer,
                                artworkLoader: artworkLoader,
                                onSelectTrack: onSelectTrack,
                                onSelectArtist: onSelectArtist,
                                onPlayTrack: onPlayTrack
                            )
                        }
                    }
                    .padding(.bottom, 16)
                } else {
                    ForEach(tracks) { track in
                        TrackListRow(
                            track: track,
                            playback: playback,
                            analyzer: analyzer,
                            artworkLoader: artworkLoader,
                            likes: likes,
                            onAddToQueue: onAddToQueue,
                            onSelectTrack: onSelectTrack,
                            onSelectArtist: onSelectArtist,
                            onPlayTrack: onPlayTrack
                        )
                    }
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
