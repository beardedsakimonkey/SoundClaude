import Foundation
import SwiftUI

struct LikesView: View {
    let user: SoundCloudUser
    let isActive: Bool
    let artworkLoader: ArtworkLoader
    let appErrorMessage: String?
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onAddToQueue: (SoundCloudTrack) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void
    let onShuffle: () async -> Void

    @ObservedObject private var likes: LikesController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var searchText: String
    @AppStorage("likesTrackLayout") private var trackLayout = TrackLayout.list
    @FocusState private var isSearchFocused: Bool
    @State private var isHoveringShuffle = false
    private let playback: PlaybackController
    private let analyzer: SpectrumAnalyzer

    init(
        user: SoundCloudUser,
        searchText: Binding<String>,
        isActive: Bool = true,
        likes: LikesController,
        playback: PlaybackController,
        analyzer: SpectrumAnalyzer,
        artworkLoader: ArtworkLoader,
        appErrorMessage: String?,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onAddToQueue: @escaping (SoundCloudTrack) -> Void,
        onPlayTrack: @escaping (SoundCloudTrack) async -> Void,
        onShuffle: @escaping () async -> Void
    ) {
        self.user = user
        self.isActive = isActive
        _searchText = searchText
        self.artworkLoader = artworkLoader
        self.appErrorMessage = appErrorMessage
        self.onSelectArtist = onSelectArtist
        self.onSelectTrack = onSelectTrack
        self.onAddToQueue = onAddToQueue
        self.onPlayTrack = onPlayTrack
        self.onShuffle = onShuffle
        _likes = ObservedObject(wrappedValue: likes)
        self.playback = playback
        self.analyzer = analyzer
    }

    var body: some View {
        ZStack(alignment: .top) {
            RouteGradientBackdrop()

            ScrollbarReservedScrollView { _ in
                VStack(spacing: 0) {
                    header
                    errorBanner
                    trackList
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                            value: likes.tracks.map(\.urn)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await likes.loadLikedTracks() }
        .onChange(of: isActive) { _, active in
            if !active { isSearchFocused = false }
        }
    }

    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline) {
                Text("Likes")
                    .font(.largeTitle.weight(.semibold))
                Text("(\(likes.tracks.count))")
                    .font(.largeTitle.weight(.regular))
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await onShuffle() }
            } label: {
                Label("Shuffle likes", systemImage: "shuffle")
                    .labelStyle(.iconOnly)
                    .font(.title.weight(.regular))
                    .foregroundStyle(.primary)
                    .opacity(likes.tracks.isEmpty ? 0.3 : (isHoveringShuffle ? 1 : 0.6))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(likes.tracks.isEmpty)
            .onContentHover { isHoveringShuffle = $0 }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHoveringShuffle)
            .help("Shuffle likes")
            Spacer()
            if likes.isLoading {
                ProgressView()
                    .accessibilityLabel("Syncing likes")
                    .controlSize(.small)
            }
            searchBar
                .frame(maxWidth: 280)
            TrackLayoutPicker(trackLayout: $trackLayout)
        }
        .padding(20)
    }

    private var searchBar: some View {
        SearchTextField(
            placeholder: "Filter",
            text: $searchText,
            isFocused: $isSearchFocused,
            accessibilityLabel: "Search liked tracks",
            style: .compact,
            preventsAutomaticFocus: true
        )
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredTracks: [SoundCloudTrack] {
        // Normalize styled Unicode letters to their plain equivalents for matching.
        let query = searchQuery.precomposedStringWithCompatibilityMapping
        guard !query.isEmpty else { return likes.tracks }
        return likes.tracks.filter {
            $0.title.precomposedStringWithCompatibilityMapping.localizedStandardContains(query)
                || $0.artist.username.precomposedStringWithCompatibilityMapping.localizedStandardContains(query)
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
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if likes.tracks.isEmpty,
           !likes.isLoading,
           !likes.canLoadMore {
            EmptyStateView("No liked tracks")
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            let tracks = filteredTracks
            LazyVStack(alignment: .leading, spacing: 0) {
                if tracks.isEmpty, !searchQuery.isEmpty {
                    EmptyStateView("No matching tracks")
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
                                likes: likes,
                                onAddToQueue: onAddToQueue,
                                onSelectTrack: onSelectTrack,
                                onSelectArtist: onSelectArtist,
                                onPlayTrack: onPlayTrack
                            )
                            .opacity(likes.isLiked(track) ? 1 : 0.5)
                            .animation(
                                reduceMotion ? nil : .easeInOut(duration: 0.2),
                                value: likes.isLiked(track)
                            )
                            .transition(
                                reduceMotion ? .identity : .scale(scale: 0.9).combined(with: .opacity)
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
                        .opacity(likes.isLiked(track) ? 1 : 0.5)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.2),
                            value: likes.isLiked(track)
                        )
                        .transition(
                            reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity)
                        )
                    }
                }

                if likes.canLoadMore {
                    paginationRow
                }
            }
            .padding(.horizontal, 20)
            // The header supplies the other 20 points of the 24-point gap.
            .padding(.top, 4)
            .padding(.bottom, 20)
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
