import Observation
import SwiftUI

enum TrackLayout: String, CaseIterable {
    case list
    case grid

    var title: String { self == .grid ? "Grid view" : "List view" }
    var symbol: String { self == .grid ? "square.grid.2x2.fill" : "list.bullet" }
}

struct TrackLayoutPicker: View {
    @Binding var trackLayout: TrackLayout
    @State private var hoveredLayout: TrackLayout?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TrackLayout.allCases, id: \.self) { layout in
                let isSelected = trackLayout == layout
                let isHovered = hoveredLayout == layout && !isSelected

                Button {
                    trackLayout = layout
                } label: {
                    Image(systemName: layout.symbol)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .foregroundStyle(trackLayout == layout ? Color.accentColor : Color.secondary)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.primary.opacity(isHovered ? 0.1 : 0))
                        }
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
                }
                .buttonStyle(.plain)
                .onContentHover { isHovering in
                    if isHovering {
                        hoveredLayout = layout
                    } else if hoveredLayout == layout {
                        hoveredLayout = nil
                    }
                }
                .contentHelp(layout.title)
                .accessibilityLabel(layout.title)
                .accessibilityAddTraits(trackLayout == layout ? .isSelected : [])
            }
        }
    }
}

private enum TrackGridMetrics {
    // 150 points is 300 pixels at 2x, matching the .square300 artwork.
    static let tileWidth: CGFloat = 150
    static let minimumColumnSpacing: CGFloat = 20

    static func columnCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width + minimumColumnSpacing) / (tileWidth + minimumColumnSpacing)))
    }
}

// Spread fixed-width tiles from edge to edge. The width lives here so that resizing
// reuses the stored content instead of re-evaluating the parent's tiles.
private struct JustifiedTrackGrid<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var width: CGFloat = 0

    private var columns: [GridItem] {
        let count = TrackGridMetrics.columnCount(forWidth: width)
        let spacing = count > 1
            ? (width - TrackGridMetrics.tileWidth * CGFloat(count)) / CGFloat(count - 1)
            : 0
        return Array(
            repeating: GridItem(.fixed(TrackGridMetrics.tileWidth), spacing: spacing, alignment: .top),
            count: count
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            content
        }
        // The zero minimum lets this shrink below the fixed columns' current width.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// Share the same look-ahead behavior across likes, history, and collections.
// Visibility changes update a coordinator, not SwiftUI state for the whole grid.
struct TrackArtworkGrid<Content: View>: View {
    let tracks: [SoundCloudTrack]
    let loader: ArtworkLoader
    @ViewBuilder let content: (SoundCloudTrack) -> Content

    // Speculatively load two rows below the visible tiles.
    private static var prefetchRowCount: Int { 2 }

    @State private var coordinator = TrackScrollArtworkPrefetcher(
        rendition: .square300,
        lookahead: prefetchRowCount
    )
    #if DEBUG
    private let prefetchSettings = ArtworkPrefetchDebugSettings.shared
    private var prefetchEnabled: Bool { prefetchSettings.isEnabled }
    #else
    private let prefetchEnabled = true
    #endif

    var body: some View {
        JustifiedTrackGrid {
            ForEach(tracks) { track in
                content(track)
                    .onAppear { coordinator.setVisible(track.id, isVisible: true, loader: loader) }
                    .onDisappear { coordinator.setVisible(track.id, isVisible: false, loader: loader) }
            }
        }
        #if DEBUG
        .preference(key: TrackArtworkQueueDebugKey.self, value: [coordinator.prefetcher])
        #endif
        .onGeometryChange(for: Int.self) { geometry in
            TrackGridMetrics.columnCount(forWidth: geometry.size.width)
        } action: { columnCount in
            coordinator.setLookahead(columnCount * Self.prefetchRowCount, loader: loader)
        }
        .onChange(of: tracks, initial: true) { _, tracks in
            configure(tracks)
        }
        .onAppear { configure(tracks) }
        .onChange(of: prefetchEnabled) { _, _ in configure(tracks) }
        .onDisappear { coordinator.stop(loader: loader) }
    }

    private func configure(_ tracks: [SoundCloudTrack]) {
        coordinator.configure(ids: tracks.map(\.id), urls: tracks.map(\.displayArtworkURL),
                              loader: loader, isEnabled: prefetchEnabled)
    }
}

// Visibility changes update a coordinator, not SwiftUI state for the whole list.
struct TrackArtworkList<Content: View>: View {
    let tracks: [SoundCloudTrack]
    let loader: ArtworkLoader
    @ViewBuilder let content: (SoundCloudTrack) -> Content

    @State private var coordinator = TrackScrollArtworkPrefetcher(rendition: .source, lookahead: 8)
    #if DEBUG
    private let prefetchSettings = ArtworkPrefetchDebugSettings.shared
    private var prefetchEnabled: Bool { prefetchSettings.isEnabled }
    #else
    private let prefetchEnabled = true
    #endif

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(tracks) { track in
                content(track)
                    .onAppear { coordinator.setVisible(track.id, isVisible: true, loader: loader) }
                    .onDisappear { coordinator.setVisible(track.id, isVisible: false, loader: loader) }
            }
        }
        #if DEBUG
        .preference(key: TrackArtworkQueueDebugKey.self, value: [coordinator.prefetcher])
        #endif
        .onChange(of: tracks, initial: true) { _, tracks in
            configure(tracks)
        }
        .onAppear { configure(tracks) }
        .onChange(of: prefetchEnabled) { _, _ in configure(tracks) }
        .onDisappear { coordinator.stop(loader: loader) }
    }

    private func configure(_ tracks: [SoundCloudTrack]) {
        coordinator.configure(ids: tracks.map(\.id), urls: tracks.map(\.displayArtworkURL),
                              loader: loader, isEnabled: prefetchEnabled)
    }
}

struct TrackGridTile: View {
    private static let artworkCornerRadius: CGFloat = 10

    let track: SoundCloudTrack
    let playback: PlaybackController
    let analyzer: SpectrumAnalyzer
    let artworkLoader: ArtworkLoader
    let likes: LikesController
    let onAddToQueue: (SoundCloudTrack) -> Void
    var onRemoveFromPlaylist: ((SoundCloudTrack) -> Void)? = nil
    var isUpdatingPlaylist = false
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @State private var isHoveringArtwork = false
    @State private var hasHoveredArtwork = false
    @State private var isHoveringTitle = false
    @State private var isHoveringMenu = false
    @State private var likeErrorMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCurrentTrack: Bool {
        playback.currentTrack?.urn == track.urn
    }

    var body: some View {
        let isPlaybackActive = isCurrentTrack && playback.isPlaybackActive
        let isLiked = likes.isLiked(track)
        let likeCount = likes.likeCount(for: track)

        VStack(alignment: .leading, spacing: 8) {
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
                    size: TrackGridMetrics.tileWidth,
                    rendition: .square300,
                    shape: RoundedRectangle(cornerRadius: Self.artworkCornerRadius, style: .continuous),
                    showsBorder: false
                )
                .scaleEffect(isHoveringArtwork && !reduceMotion ? 1.08 : 1)
                .clipShape(RoundedRectangle(cornerRadius: Self.artworkCornerRadius, style: .continuous))
                .modifier(PlayerArtworkGlass(
                    cornerRadius: Self.artworkCornerRadius
                ))
                .animation(
                    reduceMotion ? nil : isHoveringArtwork
                        ? .spring(response: 0.35, dampingFraction: 0.75)
                        : .spring(duration: 0.34, bounce: 0),
                    value: isHoveringArtwork
                )
                .overlay {
                    AnimatedPlayPauseIcon(isPlaybackActive: isPlaybackActive, size: 32)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                        .scaleEffect(reduceMotion || isHoveringArtwork || isCurrentTrack ? 1 : 0.8)
                        .opacity((isHoveringArtwork || isCurrentTrack) && track.access != .protected ? 1 : 0)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.15),
                            value: isHoveringArtwork || isCurrentTrack
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .disabled(track.access == .protected)
            .opacity(track.access == .protected ? protectedTrackOpacity : 1)
            .contentHelp(isPlaybackActive ? "Pause" : "Play")
            .accessibilityLabel("\(isPlaybackActive ? "Pause" : "Play"): \(track.title)")
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    // Mounting a Menu is expensive, so wait for the first hover. It stays
                    // mounted afterward so that leaving the tile can't remove an open menu.
                    if hasHoveredArtwork {
                        overflowMenu
                            .padding(8)
                            .opacity(isHoveringArtwork ? 1 : 0)
                            .allowsHitTesting(isHoveringArtwork)
                            .accessibilityHidden(!isHoveringArtwork)
                            // Fade in on the first hover, when the menu is inserted already opaque.
                            .transition(.opacity)
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.15),
                    value: isHoveringArtwork
                )
            }
            .onContentHover { hovering in
                isHoveringArtwork = hovering
                if hovering { hasHoveredArtwork = true }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text(track.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isCurrentTrack ? Color.accentColor : Color.primary)
                            .underline(isHoveringTitle)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onContentHover { isHoveringTitle = $0 }
                    .contentHelp(track.title)
                    if track.access == .preview {
                        TrackPreviewBadge()
                    }
                }
                .modifier(TrackPlaybackTitleInset(inset: isCurrentTrack ? 16 : 0))
                .overlay(alignment: .leading) {
                    if isCurrentTrack {
                        TrackPlaybackIndicator(
                            isPlaying: playback.isPlaybackActive,
                            isLoading: playback.isLoading,
                            speed: playback.playbackRate
                        )
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.2),
                    value: isCurrentTrack
                )

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    if likeCount != nil || isLiked {
                        Text("·")
                            .accessibilityHidden(true)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Image(systemName: isLiked ? "heart.fill" : "heart")
                            if let likeCount {
                                Text(likeCount.formatted())
                            }
                        }
                        .font(.system(size: 9))
                        .fixedSize()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            [isLiked ? "Liked" : nil, likeCount.map { "\($0.formatted()) likes" }]
                                .compactMap { $0 }
                                .joined(separator: ", ")
                        )
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .opacity(track.access == .protected ? protectedTrackOpacity : 1)
        }
        .contentShape(Rectangle())
        .trackDraggable(track)
        .contextMenu {
            trackMenuItems
        }
        .alert("Could not update like", isPresented: Binding(
            get: { likeErrorMessage != nil },
            set: { if !$0 { likeErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { likeErrorMessage = nil }
        } message: {
            Text(likeErrorMessage ?? "Please try again.")
        }
        #if DEBUG
        .debugViewUpdates("TrackGridTile")
        #endif
    }

    private var trackMenuItems: some View {
        TrackMenuItems(
            track: track,
            likes: likes,
            likeErrorMessage: $likeErrorMessage,
            onAddToQueue: onAddToQueue,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            isUpdatingPlaylist: isUpdatingPlaylist
        )
    }

    private var overflowMenu: some View {
        Menu {
            trackMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(isHoveringMenu ? 0.75 : 0.55), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More options for \(track.title)")
        .contentHelp("More options")
        .onContentHover { isHoveringMenu = $0 }
    }
}

#if DEBUG
// Shared across lists, grids, and the debug panel; reset on each app launch.
@MainActor
@Observable
private final class ArtworkPrefetchDebugSettings {
    static let shared = ArtworkPrefetchDebugSettings()
    var isEnabled = true
}

// Read counts only in this small overlay so artwork
// completions do not cause the grid itself to rebuild.
struct TrackArtworkQueueDebugKey: PreferenceKey {
    static let defaultValue: [TrackArtworkPrefetcher] = []

    static func reduce(value: inout [TrackArtworkPrefetcher], nextValue: () -> [TrackArtworkPrefetcher]) {
        value.append(contentsOf: nextValue())
    }
}

struct TrackArtworkQueueDebugOverlay: View {
    let prefetcher: TrackArtworkPrefetcher
    @AppStorage("debug.showArtworkQueues") private var isVisible = false
    @Bindable private var prefetchSettings = ArtworkPrefetchDebugSettings.shared

    private var scale: Int {
        max(24, prefetcher.visibleCount,
            prefetcher.prefetchWaitingCount + prefetcher.prefetchActiveCount)
    }

    var body: some View {
        if isVisible { panel }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Prefetch", isOn: $prefetchSettings.isEnabled)
                .toggleStyle(.switch)
                .foregroundStyle(.white)
                .frame(width: 240)
            queueBar("Visible", waiting: 0, active: prefetcher.visibleWaitingCount)
            queueBar("Prefetch", waiting: prefetcher.prefetchWaitingCount,
                     active: prefetcher.prefetchActiveCount)
            HStack(spacing: 16) {
                legend("Waiting", color: .orange)
                legend("Active", color: .cyan)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .monospacedDigit()
        .padding(14)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .padding(16)
        .transaction { $0.animation = nil }
    }

    private func queueBar(_ title: String, waiting: Int, active: Int) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(waiting + active)")
            }
            .foregroundStyle(.white)

            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.15))
                HStack(spacing: 0) {
                    Rectangle().fill(.cyan)
                        .frame(width: 240 * CGFloat(active) / CGFloat(scale))
                    Rectangle().fill(.orange)
                        .frame(width: 240 * CGFloat(waiting) / CGFloat(scale))
                }
            }
            .frame(height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: 240)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(waiting) waiting, \(active) active")
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
            Text(title).foregroundStyle(.white)
        }
    }
}
#endif
