import Foundation
import SwiftUI

struct LikesView: View {
    private enum TrackLayout: String, CaseIterable {
        case grid
        case list

        var title: String { self == .grid ? "Grid view" : "List view" }
        var symbol: String { self == .grid ? "square.grid.2x2.fill" : "list.bullet" }
    }

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
        ScrollView {
            VStack(spacing: 0) {
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
            HStack(alignment: .firstTextBaseline) {
                Text("Likes")
                    .font(.largeTitle.weight(.semibold))
                Text("(\(likes.tracks.count))")
                    .font(.title.weight(.regular))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if likes.isLoading {
                Text("Syncing likes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
            }
            HStack(spacing: 4) {
                ForEach(TrackLayout.allCases, id: \.self) { layout in
                    Button {
                        trackLayout = layout
                    } label: {
                        Image(systemName: layout.symbol)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                            .foregroundStyle(trackLayout == layout ? Color.accentColor : Color.secondary)
                            .background {
                                if trackLayout == layout {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.accentColor.opacity(0.12))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(layout.title)
                    .accessibilityLabel(layout.title)
                    .accessibilityAddTraits(trackLayout == layout ? .isSelected : [])
                }
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
                            LikedTrackGridTile(
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

private struct LikedTrackGridTile: View {
    let track: SoundCloudTrack
    let playback: PlaybackController
    let analyzer: SpectrumAnalyzer
    let artworkLoader: ArtworkLoader
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @State private var isHoveringArtwork = false
    @State private var isHoveringTitle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCurrentTrack: Bool {
        playback.currentTrack?.urn == track.urn
    }

    var body: some View {
        let isPlaybackActive = isCurrentTrack && playback.isPlaybackActive

        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                Button {
                    if isCurrentTrack {
                        playback.togglePlayPause()
                    } else {
                        Task { await onPlayTrack(track) }
                    }
                } label: {
                    TrackArtworkView(
                        artworkURL: track.displayArtworkURL,
                        loader: artworkLoader,
                        size: geometry.size.width,
                        rendition: .square500,
                        shape: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay {
                        if isHoveringArtwork || isCurrentTrack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.black.opacity(0.35))
                                .overlay {
                                    Image(systemName: isPlaybackActive ? "pause.fill" : "play.fill")
                                        .font(.system(size: 32, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .onContentHover { isHoveringArtwork = $0 }
                .help(isPlaybackActive ? "Pause" : "Play")
                .accessibilityLabel("\(isPlaybackActive ? "Pause" : "Play"): \(track.title)")
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        onSelectTrack(track)
                    } label: {
                        HStack(spacing: 6) {
                            if isCurrentTrack {
                                TrackPlaybackIndicator(isPlaying: playback.isPlaying, analyzer: analyzer)
                            }
                            Text(track.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(isCurrentTrack ? Color.orange : Color.primary)
                                .underline(isHoveringTitle)
                                .multilineTextAlignment(.leading)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.2),
                            value: isCurrentTrack
                        )
                    }
                    .buttonStyle(.plain)
                    .onContentHover { isHoveringTitle = $0 }
                    .help(track.title)
                    if track.access == .preview {
                        TrackPreviewBadge()
                    }
                }

                ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        }
    }
}
