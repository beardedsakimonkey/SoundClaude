import Foundation

enum SearchScope: Hashable {
    case query
    case genre
    case tag
}

/// A page to warm before navigating to it, so that it opens with its content.
enum PrefetchTarget: Hashable {
    case track(SoundCloudTrack)
    /// The "View all" page for the playlists that a track is in.
    case trackPlaylists(SoundCloudTrack)
    /// The artist page's header and Tracks tab. A page that opens on another
    /// tab also needs `artistTab`.
    case artist(SoundCloudUser)
    case artistTab(SoundCloudUser, ArtistContentTab)
    case artistComments(SoundCloudUser)
    case search(String, SearchScope)
    /// Every match of one kind for a query.
    case searchCategory(String, SearchCategory)
    case station(String)
    case playlist(SoundCloudPlaylist)
    /// The rendition that the full-size viewer shows.
    case fullSizeImage(URL)
}

// Each target warms what its page reads as it opens: the caches its init reads
// and the content visible after the entrance. Later content loads with the page.
extension AppModel {
    /// Starts warming and returns at once. Failures are ignored: the page retries them.
    func prefetch(_ target: PrefetchTarget) {
        Task { await warm(target) }
    }

    private func warm(_ target: PrefetchTarget) async {
        switch target {
        case let .track(track):
            await warmTrackPage(track)
        case let .trackPlaylists(track):
            await warmTrackPlaylists(track)
        case let .artist(artist):
            await warmArtistPage(artist)
        case let .artistTab(artist, tab):
            await warmArtistTab(artist, tab)
        case let .artistComments(artist):
            _ = try? await artistComments(for: artist)
        case let .search(query, scope):
            switch scope {
            case .query: _ = try? await searchResults(query: query)
            case .genre: _ = try? await searchTracks(genres: query)
            case .tag: _ = try? await searchTracks(tags: query)
            }
        case let .searchCategory(query, category):
            await warmSearchCategory(query, category)
        case let .station(urn):
            _ = try? await station(urn: urn)
        case let .playlist(playlist):
            await warmPlaylist(playlist)
        case let .fullSizeImage(url):
            _ = try? await artworkLoader.data(for: url, rendition: .original)
        }
    }

    // Comments appear after the page's entrance, so the page loads them itself.
    private func warmTrackPage(_ track: SoundCloudTrack) async {
        async let details = try? trackDetails(for: track)
        async let waveform = try? waveform(for: track)
        async let artwork: Void = prefetchDetailArtwork(for: track)
        _ = await (details, waveform, artwork)
    }

    // The cards that the page opens on each load a track preview and a cover.
    private func warmTrackPlaylists(_ track: SoundCloudTrack) async {
        guard let page = try? await playlistsContaining(track) else { return }
        await withTaskGroup(of: Void.self) { group in
            for playlist in page.playlists.prefix(3) {
                group.addTask { await self.playlists.loadPreview(playlist) }
                group.addTask { await self.warmImage(playlist.artworkURL, rendition: .square500) }
            }
        }
    }

    private func warmArtistPage(_ artist: SoundCloudUser) async {
        async let details = try? artistDetails(for: artist)
        async let backdrop: Void = warmArtistBackdrop(artist)
        async let picture: Void = warmImage(artist.avatarURL, rendition: .square500)
        async let tracks: Void = warmArtistTab(artist, .tracks)
        async let profiles: Void = warmArtistWebProfiles(artist)
        async let sidebar: Void = warmArtistSidebar(artist)
        _ = await (details, backdrop, picture, tracks, profiles, sidebar)
    }

    private func warmArtistSidebar(_ artist: SoundCloudUser) async {
        guard let user = await artistWithURN(artist) else { return }
        async let related = try? relatedArtists(for: user)
        async let comments = try? artistComments(for: user)
        _ = await (related, comments)
    }

    private func warmArtistBackdrop(_ artist: SoundCloudUser) async {
        do {
            guard try await artistHeader(for: artist) == nil else { return }
        } catch {
            // A failed lookup does not confirm that the header is absent.
            return
        }
        // Without a profile header, the backdrop shows the avatar's source rendition.
        await warmImage(artist.avatarURL)
    }

    private func warmArtistWebProfiles(_ artist: SoundCloudUser) async {
        guard let user = await artistWithURN(artist) else { return }
        _ = try? await artistWebProfiles(for: user)
    }

    private func warmArtistTab(_ artist: SoundCloudUser, _ tab: ArtistContentTab) async {
        guard let user = await artistWithURN(artist) else { return }
        switch tab {
        case .tracks:
            _ = try? await artistTracks(for: user)
        case .reposts:
            async let tracks = try? artistReposts(for: user)
            async let playlists = try? artistPlaylistReposts(for: user)
            _ = await (tracks, playlists)
        case .playlists:
            _ = try? await artistPlaylists(for: user)
        case .likes:
            async let tracks = try? artistLikes(for: user)
            async let playlists = try? artistPlaylistLikes(for: user)
            _ = await (tracks, playlists)
        }
    }

    /// Content requests are keyed by URN, which some lists omit until details load.
    private func artistWithURN(_ artist: SoundCloudUser) async -> SoundCloudUser? {
        if artist.urn != nil { return artist }
        return try? await artistDetails(for: artist).user
    }

    private func warmSearchCategory(_ query: String, _ category: SearchCategory) async {
        switch category {
        case .top:
            _ = try? await searchResults(query: query)
        case .tracks:
            _ = try? await searchTracks(query: query)
        case .playlists:
            _ = try? await searchPlaylists(query: query)
        case .albums:
            _ = try? await searchAlbums(query: query)
        case .users:
            _ = try? await searchUsers(query: query)
        }
    }

    // A playlist with saved contents opens with them and refreshes in place.
    private func warmPlaylist(_ playlist: SoundCloudPlaylist) async {
        await playlists.restoreContents(urn: playlist.urn)
        guard playlists.cache.contents[playlist.urn] == nil else { return }
        await playlists.loadPlaylist(playlist)
    }

    private func warmImage(_ url: URL?, rendition: ArtworkLoader.Rendition = .source) async {
        guard let url else { return }
        _ = try? await artworkLoader.image(for: url, rendition: rendition)
    }
}
