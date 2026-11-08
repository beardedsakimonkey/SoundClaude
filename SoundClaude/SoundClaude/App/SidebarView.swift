import SwiftUI

struct SidebarView: View {
    let selection: SidebarDestination?
    let onSelect: (SidebarDestination) -> Void
    let currentPlaylistURN: String?
    let currentStationURN: String?
    let playbackSource: TrackQueue.Source
    let playback: PlaybackController
    @ObservedObject var playlists: PlaylistsController
    let likes: LikesController
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let onPlayLikes: () async -> Void
    let onShuffleLikes: () async -> Void
    let onSelectStation: (SoundCloudStationLikePage.Station) -> Void
    let onPlayStation: (SoundCloudStationLikePage.Station, _ shuffle: Bool) async throws -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onPlayPlaylist: (SoundCloudPlaylist, PlaylistContents, _ shuffle: Bool) async -> Void
    let onDeletePlaylist: (SoundCloudPlaylist) -> Void
    let onSelectProfile: (SoundCloudUser) -> Void
    let onReselect: () -> Void
    let onSignOut: () async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSidebarFocused: Bool
    @State private var isShowingCreatePlaylist = false
    @State private var dropTargetURN: String?
    @State private var addingToPlaylistURNs: Set<String> = []
    @State private var playlistDropError: String?
    @State private var playlistLikeError: String?
    @State private var startingPlaylistURN: String?
    @State private var playlistPlaybackError: String?
    @State private var startingStationURN: String?
    @State private var stationPlaybackError: String?
    @State private var stationLikeError: String?
    @State private var editingPlaylist: SoundCloudPlaylist?
    @State private var playlistDeletion = PlaylistDeletionState()
    @AppStorage("sidebarPlaylistsExpanded") private var isPlaylistsExpanded = true
    @AppStorage("sidebarLikedPlaylistsExpanded") private var isLikedPlaylistsExpanded = true

    @AppStorage("sidebarLikedStationsExpanded") private var isLikedStationsExpanded = true

    fileprivate static let sectionIndent: CGFloat = 6

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        sidebarList
        .navigationTitle("SoundClaude")
        .sheet(isPresented: $isShowingCreatePlaylist) {
            PlaylistEditorView(playlists: playlists, onSaved: onSelectPlaylist)
        }
        .sheet(item: $editingPlaylist) { playlist in
            PlaylistEditorView(playlists: playlists, playlist: playlist)
        }
        .modifier(PlaylistDeletionModifier(
            state: $playlistDeletion, playlists: playlists, onDeleted: onDeletePlaylist
        ))
        .alert("Could not add track to playlist", isPresented: Binding(
            get: { playlistDropError != nil },
            set: { if !$0 { playlistDropError = nil } }
        )) {
            Button("OK", role: .cancel) { playlistDropError = nil }
        } message: {
            Text(playlistDropError ?? "Please try again.")
        }
        .alert("Could not unlike playlist", isPresented: Binding(
            get: { playlistLikeError != nil },
            set: { if !$0 { playlistLikeError = nil } }
        )) {
            Button("OK", role: .cancel) { playlistLikeError = nil }
        } message: {
            Text(playlistLikeError ?? "Please try again.")
        }
        .alert("Could not play playlist", isPresented: Binding(
            get: { playlistPlaybackError != nil },
            set: { if !$0 { playlistPlaybackError = nil } }
        )) {
            Button("OK", role: .cancel) { playlistPlaybackError = nil }
        } message: {
            Text(playlistPlaybackError ?? "Please try again.")
        }
        .alert("Could not play station", isPresented: Binding(
            get: { stationPlaybackError != nil },
            set: { if !$0 { stationPlaybackError = nil } }
        )) {
            Button("OK", role: .cancel) { stationPlaybackError = nil }
        } message: {
            Text(stationPlaybackError ?? "Please try again.")
        }
        .alert("Could not unlike station", isPresented: Binding(
            get: { stationLikeError != nil },
            set: { if !$0 { stationLikeError = nil } }
        )) {
            Button("OK", role: .cancel) { stationLikeError = nil }
        } message: {
            Text(stationLikeError ?? "Please try again.")
        }
        #if DEBUG
        .debugViewUpdates("SidebarView")
        #endif
    }

    private var sidebarList: some View {
        ScrollbarReservedScrollView(
            enablesKeyboardNavigation: false,
            reservesSpaceWhenContentFits: false
        ) { _ in
            VStack(spacing: 0) {
                SidebarAccountHeader(
                    user: user,
                    artworkLoader: artworkLoader,
                    onSelectProfile: onSelectProfile,
                    onSignOut: onSignOut
                )
                sidebarContent
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isSidebarFocused)
        .onMoveCommand { direction in
            let destinations = SidebarDestination.libraryDestinations
            let index = selection.flatMap { destinations.firstIndex(of: $0) } ?? 0
            switch direction {
            case .up: onSelect(destinations[max(0, index - 1)])
            case .down: onSelect(destinations[min(destinations.count - 1, index + 1)])
            default: break
            }
        }
        .task(id: isPlaylistsExpanded) {
            guard isPlaylistsExpanded else { return }
            await playlists.load()
        }
        .task(id: isLikedStationsExpanded) {
            guard isLikedStationsExpanded else { return }
            try? await likes.loadStationLikes()
        }
        .task(id: isLikedPlaylistsExpanded) {
            guard isLikedPlaylistsExpanded else { return }
            await playlists.loadLikes()
        }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SidebarDestination.libraryDestinations) { destination in
                SidebarRowHoverReader { isHovered in
                    let showsShuffle = destination == .liked && isHovered
                    Label {
                        Text(destination.title)
                    } icon: {
                        Image(systemName: destination.systemImage)
                            .font(.system(size: 16))
                            .frame(width: 28)
                    }
                        .modifier(SidebarRowStyle(
                            isSelected: selection == destination,
                            usesPrimaryForeground: true,
                            verticalPadding: 4,
                            fadesTrailingEdge: showsShuffle
                        ) {
                            select(destination)
                        })
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                Task { await onPlayLikes() }
                            },
                            including: destination == .liked ? .all : .none
                        )
                        .accessibilityActions {
                            if destination == .liked {
                                Button("Play likes") {
                                    Task { await onPlayLikes() }
                                }
                                .disabled(likes.tracks.isEmpty)
                                Button("Shuffle likes") {
                                    Task { await onShuffleLikes() }
                                }
                                .disabled(likes.tracks.isEmpty)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if showsShuffle {
                                sidebarShuffleButton("Shuffle likes") {
                                    Task { await onShuffleLikes() }
                                }
                                .disabled(likes.tracks.isEmpty)
                            }
                        }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Playlists", isExpanded: $isPlaylistsExpanded, isLoading: playlists.isLoading)
                sectionContents(isExpanded: isPlaylistsExpanded) {
                    Label {
                        Text("New")
                    } icon: {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 28)
                    }
                        .modifier(SidebarRowStyle(isSelected: false) {
                            isShowingCreatePlaylist = true
                        })

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(playlists.playlists) { playlist in
                            playlistRow(playlist)
                        }
                        if !playlists.isLoading, let errorMessage = playlists.errorMessage {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Try Again") { Task { await playlists.load() } }
                            }
                            .padding(.leading, Self.sectionIndent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if showsLikedSection(
                isEmpty: playlists.likedPlaylists.isEmpty,
                errorMessage: playlists.likesErrorMessage,
                isExpanded: isLikedPlaylistsExpanded,
                hasLoaded: playlists.hasLoadedLikes
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Liked Playlists", isExpanded: $isLikedPlaylistsExpanded, isLoading: playlists.isLoadingLikes)
                    sectionContents(isExpanded: isLikedPlaylistsExpanded) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(playlists.likedPlaylists) { playlist in
                                playlistRow(playlist, isUnliking: playlists.unlikingPlaylistURNs.contains(playlist.urn))
                            }
                            if !playlists.isLoadingLikes, let errorMessage = playlists.likesErrorMessage {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("Try Again") { Task { await playlists.loadLikes() } }
                                }
                                .padding(.leading, Self.sectionIndent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if showsLikedSection(
                isEmpty: likes.likedStations.isEmpty,
                errorMessage: likes.stationLikesErrorMessage,
                isExpanded: isLikedStationsExpanded,
                hasLoaded: likes.hasLoadedStationLikes
            ) {
                likedStationsSection
            }
        }
        .padding(8)
        .modifier(SidebarPlaylistRemovalAnimation(
            playlistURNs: playlists.playlists.map(\.urn),
            likedPlaylistURNs: playlists.likedPlaylists.map(\.urn),
            likedStationURNs: likes.likedStations.map(\.urn)
        ))
        // Cache restoration should show rows immediately. Section toggles animate separately.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isLikedStationsExpanded)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.25),
            value: isPlaylistsExpanded
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.25),
            value: isLikedPlaylistsExpanded
        )
    }

    // Empty sections stay hidden while loading so the header doesn't flash on launch.
    // Collapsed sections don't load, so they keep a header to expand them with.
    private func showsLikedSection(
        isEmpty: Bool, errorMessage: String?, isExpanded: Bool, hasLoaded: Bool
    ) -> Bool {
        !isEmpty || errorMessage != nil || (!isExpanded && !hasLoaded)
    }

    private var likedStationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Stations", isExpanded: $isLikedStationsExpanded,
                          isLoading: likes.isLoadingStationLikes)
            sectionContents(isExpanded: isLikedStationsExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(likes.likedStations) { station in
                        let isStarting = startingStationURN == station.urn
                        let isUpdating = likes.updatingStationURNs.contains(station.urn)
                        let shuffleTitle = station.isStation ? "Shuffle station" : "Shuffle playlist"
                        SidebarRowHoverReader { isHovered in
                            let showsShuffle = isHovered && !isStarting && !isUpdating
                            Label {
                                Text(station.displayTitle)
                            } icon: {
                                if station.isStation {
                                    StationPlayingIcon(
                                        playback: playback, isCurrent: playbackSource == .station(station.urn)
                                    )
                                    .font(.system(size: 16))
                                    .frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 16))
                                        .frame(width: 28, height: 28)
                                }
                            }
                            .lineLimit(1)
                            .contentHelp(station.displayTitle)
                            .modifier(SidebarRowStyle(
                                isSelected: false,
                                usesPrimaryForeground: station.isStation
                                    ? currentStationURN == station.urn : currentPlaylistURN == station.urn,
                                prefetch: station.isStation
                                    ? .station(station.urn)
                                    : .playlist(.systemPlaylist(urn: station.urn, title: station.displayTitle)),
                                fadesTrailingEdge: isStarting || showsShuffle
                            ) {
                                onSelectStation(station)
                            })
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                startStation(station)
                            })
                            .accessibilityAction(named: station.isStation ? "Play station" : "Play playlist") {
                                startStation(station)
                            }
                            .accessibilityAction(named: shuffleTitle) {
                                startStation(station, shuffle: true)
                            }
                            .overlay(alignment: .trailing) {
                                if isStarting {
                                    LoadingSpinner()
                                        .controlSize(.small)
                                        .frame(width: 28, height: 28)
                                        .padding(.trailing, 8)
                                        .accessibilityLabel("Loading \(station.displayTitle) for playback")
                                        .allowsHitTesting(false)
                                } else if showsShuffle {
                                    sidebarShuffleButton(shuffleTitle) {
                                        onSelectStation(station)
                                        startStation(station, shuffle: true)
                                    }
                                }
                            }
                        }
                        .opacity(isUpdating ? 0.5 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isUpdating)
                        .contextMenu {
                            Button(
                                station.isStation ? "Unlike station" : "Unlike playlist",
                                systemImage: "heart.slash"
                            ) {
                                unlikeStation(station)
                            }
                            // toggleStationLike likes anything absent from the list, so wait
                            // until a finished load confirms this row is still liked.
                            .disabled(!likes.hasLoadedStationLikes || likes.updatingStationURNs.contains(station.urn))
                        }
                    }
                    if !likes.isLoadingStationLikes, let message = likes.stationLikesErrorMessage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Try Again") { Task { try? await likes.loadStationLikes() } }
                        }
                        .padding(.leading, Self.sectionIndent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func playlistRow(_ playlist: SoundCloudPlaylist, isUnliking: Bool = false) -> some View {
        let isOwned = (playlist.owner.urn == user.urn && user.urn != nil)
            || playlist.owner.permalinkURL == user.permalinkURL
        let contents = playlists.cache.contents[playlist.urn]
        let artworkURL = playlists.artworkURL(for: playlist)
        let isPendingRemoval = isUnliking || playlists.deletingPlaylistURNs.contains(playlist.urn)
        let isStarting = startingPlaylistURN == playlist.urn
        let isAddingTrack = addingToPlaylistURNs.contains(playlist.urn)

        let row = SidebarRowHoverReader { isHovered in
            let showsShuffle = isHovered && !isStarting && !isAddingTrack && !isPendingRemoval
            Label {
                Text(playlist.title)
            } icon: {
                TrackArtworkView(
                    artworkURL: artworkURL,
                    loader: artworkLoader,
                    size: 24,
                    shape: RoundedRectangle(cornerRadius: 6, style: .continuous),
                    showsBorder: false
                )
                .frame(width: 28)
            }
                .lineLimit(1)
                .contentHelp(playlist.title)
                .task(id: playlist.urn) { await playlists.loadArtwork(for: playlist) }
                .modifier(SidebarRowStyle(
                    isSelected: false,
                    usesPrimaryForeground: currentPlaylistURN == playlist.urn,
                    prefetch: .playlist(playlist),
                    fadesTrailingEdge: isStarting || isAddingTrack || showsShuffle
                ) {
                    onSelectPlaylist(playlist)
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    startPlaylist(playlist)
                })
                .accessibilityAction(named: "Play playlist") {
                    startPlaylist(playlist)
                }
                .accessibilityAction(named: "Shuffle playlist") {
                    startPlaylist(playlist, shuffle: true)
                }
                .overlay(alignment: .trailing) {
                    if isStarting {
                        LoadingSpinner()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                            .padding(.trailing, 8)
                            .accessibilityLabel("Loading \(playlist.title) for playback")
                    } else if showsShuffle {
                        sidebarShuffleButton("Shuffle playlist") {
                            onSelectPlaylist(playlist)
                            startPlaylist(playlist, shuffle: true)
                        }
                    }
                }
        }
            .opacity(isPendingRemoval ? 0.5 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isPendingRemoval)
            .contextMenu {
                if playlists.likedPlaylistURNs.contains(playlist.urn) {
                    Button("Unlike playlist", systemImage: "heart.slash") {
                        Task { @MainActor in
                            guard playlists.likedPlaylistURNs.contains(playlist.urn) else { return }
                            do {
                                try await playlists.toggleLike(playlist)
                            } catch is CancellationError {
                            } catch {
                                playlistLikeError = "\(playlist.title): \(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(playlists.updatingLikeURNs.contains(playlist.urn))
                }
                if isOwned {
                    Button {
                        editingPlaylist = contents?.playlist ?? playlist
                    } label: {
                        Label("Edit playlist", systemImage: "pencil")
                    }
                    .disabled(playlists.updatingPlaylistURNs.contains(playlist.urn)
                        || playlistDeletion.deletingURNs.contains(playlist.urn))
                    DeletePlaylistButton(playlist: playlist, state: $playlistDeletion)
                }
            }

        if isOwned {
            row
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(dropTargetURN == playlist.urn ? 0.18 : 0))
                }
                .overlay(alignment: .trailing) {
                    if isAddingTrack, !isStarting {
                        LoadingSpinner()
                            .controlSize(.small)
                            .padding(.trailing, 8)
                            .accessibilityLabel("Adding track to \(playlist.title)")
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: TrackPlaylistDrag.self) { items, _ in
                    guard !items.isEmpty,
                          addingToPlaylistURNs.insert(playlist.urn).inserted else { return false }
                    dropTargetURN = nil
                    Task { @MainActor in
                        defer { addingToPlaylistURNs.remove(playlist.urn) }
                        do {
                            for item in items {
                                try await playlists.addTrack(item.track, to: playlist)
                            }
                        } catch is CancellationError {
                        } catch {
                            playlistDropError = "\(playlist.title): \(error.localizedDescription)"
                        }
                    }
                    return true
                } isTargeted: { isTargeted in
                    if isTargeted && !addingToPlaylistURNs.contains(playlist.urn) {
                        dropTargetURN = playlist.urn
                    } else if dropTargetURN == playlist.urn {
                        dropTargetURN = nil
                    }
                }
        } else {
            row
        }
    }

    private func startStation(_ station: SoundCloudStationLikePage.Station, shuffle: Bool = false) {
        guard startingStationURN == nil else { return }
        startingStationURN = station.urn
        Task { @MainActor in
            defer { startingStationURN = nil }
            do {
                try await onPlayStation(station, shuffle)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                stationPlaybackError = "\(station.displayTitle): \(error.localizedDescription)"
            }
        }
    }

    private func unlikeStation(_ station: SoundCloudStationLikePage.Station) {
        Task { @MainActor in
            guard likes.likedStationURNs.contains(station.urn) else { return }
            do {
                try await likes.toggleStationLike(urn: station.urn, title: station.title)
            } catch is CancellationError {
            } catch {
                stationLikeError = "\(station.displayTitle): \(error.localizedDescription)"
            }
        }
    }

    private func startPlaylist(_ playlist: SoundCloudPlaylist, shuffle: Bool = false) {
        guard startingPlaylistURN == nil else { return }
        startingPlaylistURN = playlist.urn
        Task { @MainActor in
            defer { startingPlaylistURN = nil }
            if playlists.cache.contents[playlist.urn]?.isComplete != true {
                await playlists.loadPlaylist(playlist)
            }
            guard !Task.isCancelled else { return }
            guard let contents = playlists.cache.contents[playlist.urn],
                  contents.isComplete, !contents.tracks.isEmpty else {
                playlistPlaybackError = playlists.playlistErrors[playlist.urn]
                    ?? "This playlist has no playable tracks."
                return
            }
            await onPlayPlaylist(playlist, contents, shuffle)
        }
    }

    private func sidebarShuffleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Image(systemName: "shuffle")
            .padding(.trailing, 10)
            .frame(width: 38, alignment: .trailing)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .modifier(SidebarForegroundHover(idleOpacity: 0.5))
            .modifier(SidebarMouseDownAction(action: action))
            .contentHelp(title)
            .accessibilityLabel(title)
    }

    private func sectionContents<Content: View>(
        isExpanded: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            if isExpanded {
                VStack(alignment: .leading, spacing: 0, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.modifier(
                        active: SidebarSectionSlide(progress: 0),
                        identity: SidebarSectionSlide(progress: 1)
                    ))
            }
        }
        // Keep sliding rows below the header while the section changes height.
        .clipped()
        // Clipping alone leaves hidden rows clickable over the section header.
        .contentShape(Rectangle())
    }

    private func sectionHeader(_ title: String, isExpanded: Binding<Bool>, isLoading: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if isLoading {
                LoadingSpinner()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.25),
                    value: isExpanded.wrappedValue
                )
                .accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .modifier(SidebarForegroundHover())
        .modifier(SidebarMouseDownAction {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                isExpanded.wrappedValue.toggle()
            }
        })
        .accessibilityLabel(title)
        .accessibilityValue("\(isExpanded.wrappedValue ? "Expanded" : "Collapsed")\(isLoading ? ", Loading" : "")")
        .contentHelp("\(isExpanded.wrappedValue ? "Collapse" : "Expand") \(title)")
    }

    private func select(_ destination: SidebarDestination) {
        isSidebarFocused = true
        if selection == destination {
            onReselect()
        } else {
            onSelect(destination)
        }
    }
}

private struct SidebarPlaylistRemovalAnimation: ViewModifier {
    let playlistURNs: [String]
    let likedPlaylistURNs: [String]
    let likedStationURNs: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousRows: Set<String> = []

    private var rows: Set<String> {
        Set(
            playlistURNs.map { "owned:\($0)" }
                + likedPlaylistURNs.map { "liked:\($0)" }
                + likedStationURNs.map { "station:\($0)" }
        )
    }

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                // Animate the whole sidebar so sections below the removed row also slide up.
                if !reduceMotion && !previousRows.subtracting(rows).isEmpty {
                    transaction.animation = .easeInOut(duration: 0.25)
                }
            }
            .onChange(of: rows, initial: true) { _, newRows in
                previousRows = newRows
            }
    }
}

// Apply the interpolated transform to the section itself. A built-in move
// transition can give newly inserted artwork the final position while the
// placeholder and text are still sliding.
private struct SidebarSectionSlide: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: 0,
            y: (progress - 1) * size.height
        ))
    }
}

private struct SidebarAccountHeader: View {
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let onSelectProfile: (SoundCloudUser) -> Void
    let onSignOut: () async -> Void

    @State private var isProfileHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // The badge sits outside the button so it shows its own tooltip.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Button {
                    onSelectProfile(user)
                } label: {
                    HStack(spacing: 8) {
                        TrackArtworkView(
                            artworkURL: user.avatarURL,
                            loader: artworkLoader,
                            size: 24,
                            showsBorder: false,
                            showsPlaceholderIcon: false
                        )
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                        }
                        Text(user.username)
                            .underline(isProfileHovered)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onContentHover { isProfileHovered = $0 }
                .contentHelp("View profile: \(user.username)")
                .accessibilityLabel("View profile: \(user.username)")
                if user.isVerified == true {
                    VerifiedBadge()
                        .imageScale(.small)
                }
            }
            .font(.callout.weight(.medium))

            Spacer(minLength: 0)

            Button {
                Task { await onSignOut() }
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
                    .modifier(SidebarForegroundHover(idleOpacity: 0.5))
            }
            .buttonStyle(.plain)
            .contentHelp("Sign out")
            .accessibilityLabel("Sign out")
        }
        .padding(.horizontal, 12)
    }
}

// Owns a row's hover state so hovering one row does not invalidate the whole sidebar.
private struct SidebarRowHoverReader<Content: View>: View {
    @ViewBuilder let content: (_ isHovered: Bool) -> Content
    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .onContentHover { isHovered = $0 }
    }
}

private struct SidebarRowStyle: ViewModifier {
    let isSelected: Bool
    var usesPrimaryForeground = false
    var verticalPadding: CGFloat = 2
    var prefetch: PrefetchTarget? = nil
    var fadesTrailingEdge = false
    let onSelect: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .mask {
                if fadesTrailingEdge {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 24)
                        // Clears the overlay, which sits in the last ~18pt of this frame.
                        Color.clear.frame(width: 22)
                    }
                } else {
                    Color.black
                }
            }
            // Indent inside the row so its background and hit target still reach the sidebar edge.
            .padding(.leading, 8 + SidebarView.sectionIndent)
            .padding(.trailing, 8)
            .padding(.vertical, verticalPadding)
            .contentShape(Rectangle())
            .modifier(SidebarMouseDownAction(action: onSelect))
            // Rows open on mouse down, so a press is already too late to prefetch.
            .prefetch(prefetch, .hoverOnly)
            .modifier(SidebarForegroundHover(isSelected: isSelected, usesPrimaryForeground: usesPrimaryForeground))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.06 : 0))
            }
    }
}

private struct SidebarMouseDownAction: ViewModifier {
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        if isEnabled { action() }
                    }
                    .onEnded { _ in isPressed = false }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if isEnabled { action() } }
    }
}

private struct SidebarForegroundHover: ViewModifier {
    var isSelected = false
    var usesPrimaryForeground = false
    var idleOpacity: Double = 1
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var foregroundColor: Color {
        if isSelected {
            return Color("AccentColor")
        }
        if usesPrimaryForeground {
            return .primary
        }
        return isHovered ? .primary : .secondary
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foregroundColor)
            .opacity(isHovered ? 1 : idleOpacity)
            .onContentHover { isHovered = $0 }
    }
}

// Reads playback state in its own body so play/pause does not invalidate the screen showing it.
struct StationPlayingIcon: View {
    let playback: PlaybackController
    let isCurrent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contentAnimationsPaused) private var contentAnimationsPaused

    var body: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .symbolEffect(
                .variableColor.iterative,
                isActive: isCurrent && playback.isPlaybackActive && !reduceMotion && !contentAnimationsPaused
            )
    }
}

/// `music.note.list` has no left-to-right layer order for `.variableColor`, so this sweeps
/// a mask across it with the timing of `.variableColor.iterative` on `StationPlayingIcon`.
struct PlaylistPlayingIcon: View {
    let playback: PlaybackController
    let isCurrent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contentAnimationsPaused) private var contentAnimationsPaused
    @State private var startDate: Date?
    @State private var stopDate: Date?

    var body: some View {
        let isActive = isCurrent && playback.isPlaybackActive && !reduceMotion && !contentAnimationsPaused
        let symbol = Image(systemName: "music.note.list")
        TimelineView(.animation(paused: startDate == nil)) { context in
            if let startDate {
                symbol.mask {
                    LinearGradient(
                        stops: Self.sweepStops(
                            elapsed: context.date.timeIntervalSince(startDate),
                            sinceStop: stopDate.map { context.date.timeIntervalSince($0) }
                        ),
                        startPoint: UnitPoint(x: 0, y: 0.8),
                        endPoint: UnitPoint(x: 1, y: 0.2)
                    )
                }
            } else {
                symbol
            }
        }
        .task(id: isActive) {
            if isActive {
                startDate = .now
                stopDate = nil
            } else if startDate != nil {
                // Keep sweeping while the dimming fades out, then stop the timeline.
                stopDate = .now
                try? await Task.sleep(for: .seconds(Self.fadeOut))
                guard !Task.isCancelled else { return }
                startDate = nil
                stopDate = nil
            }
        }
    }

    private static let period = 2.2
    private static let sweep = 0.65
    private static let rise = 0.2
    private static let hold = 0.2
    private static let decay = 0.85
    private static let idleOpacity = 0.35
    private static let fadeIn = 0.3
    private static let fadeOut = 0.4
    private static let sampleCount = 16

    private static func sweepStops(elapsed: TimeInterval, sinceStop: TimeInterval?) -> [Gradient.Stop] {
        var dimming = min(1, max(0, elapsed / fadeIn))
        if let sinceStop {
            let progress = min(1, max(0, sinceStop / fadeOut))
            dimming *= 1 - progress * progress * (3 - 2 * progress)
        }
        return (0..<sampleCount).map { index in
            let location = Double(index) / Double(sampleCount - 1)
            var local = (elapsed - location * sweep).truncatingRemainder(dividingBy: period)
            if local < 0 { local += period }
            let lit = idleOpacity + (1 - idleOpacity) * intensity(at: local)
            let opacity = 1 - dimming * (1 - lit)
            return Gradient.Stop(color: .black.opacity(opacity), location: location)
        }
    }

    private static func intensity(at time: TimeInterval) -> Double {
        if time < rise { return time / rise }
        if time < rise + hold { return 1 }
        let progress = min(1, (time - rise - hold) / decay)
        return 1 - progress * progress * (3 - 2 * progress)
    }
}
