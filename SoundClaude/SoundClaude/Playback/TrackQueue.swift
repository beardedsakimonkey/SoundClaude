import Foundation

struct TrackQueue: Codable {
    enum Source: Codable, Equatable {
        case feed
        case history
        case search(String)
        case genre(String)
        case tag(String)
        case likes
        case artist(String)
        case artistReposts(String)
        case artistLikes(String)
        case playlist(String)
        case station(String)
        case related(String)
        case single
    }

    let source: Source
    let stationTitle: String?
    private(set) var tracks: [SoundCloudTrack]
    private(set) var nextPageURL: URL?
    private var loadedPageURLs: Set<URL> = []
    private var shuffledURNs: [String] = []
    // Optional so queues saved before eager shuffle still decode.
    private var shuffleEnabled: Bool?
    private var reorderedLikesURNs: [String]?
    // Keep manually added tracks when a likes queue refreshes or saves without library metadata.
    private var addedLikesTracks: [SoundCloudTrack]?
    // Optional for compatibility with previously saved queues.
    private var removedURNs: Set<String>?

    init(source: Source, tracks: [SoundCloudTrack], nextPageURL: URL? = nil, stationTitle: String? = nil) {
        self.source = source
        self.stationTitle = stationTitle
        var known = Set<String>()
        self.tracks = tracks.filter { known.insert($0.urn).inserted }
        self.nextPageURL = nextPageURL
    }

    @discardableResult
    mutating func add(_ track: SoundCloudTrack, after currentURN: String? = nil) -> Bool {
        guard track.urn != currentURN else { return false }
        removedURNs?.remove(track.urn)
        let isNew = !tracks.contains { $0.urn == track.urn }
        if isNew {
            tracks.append(track)
            if source == .likes {
                addedLikesTracks = (addedLikesTracks ?? []) + [track]
                reorderedLikesURNs = tracks.map(\.urn)
            }
            updateShuffleOrder()
        }
        let order = playbackTracks
        if let currentIndex = order.firstIndex(where: { $0.urn == currentURN }),
           let addedIndex = order.firstIndex(where: { $0.urn == track.urn }) {
            let moved = move(fromOffsets: IndexSet(integer: addedIndex), toOffset: currentIndex + 1)
            return isNew || moved
        }
        return isNew
    }

    @discardableResult
    mutating func remove(_ track: SoundCloudTrack) -> Bool {
        guard tracks.contains(where: { $0.urn == track.urn }) else { return false }
        removedURNs = (removedURNs ?? []).union([track.urn])
        tracks.removeAll { $0.urn == track.urn }
        shuffledURNs.removeAll { $0 == track.urn }
        reorderedLikesURNs?.removeAll { $0 == track.urn }
        addedLikesTracks?.removeAll { $0.urn == track.urn }
        return true
    }

    mutating func append(_ page: SoundCloudTrackPage) throws {
        if let next = page.nextURL,
           next == nextPageURL || loadedPageURLs.contains(next) {
            throw SoundCloudError.invalidData
        }
        if let nextPageURL { loadedPageURLs.insert(nextPageURL) }
        var known = Set(tracks.map(\.urn))
        known.formUnion(removedURNs ?? [])
        tracks.append(contentsOf: page.tracks.filter { known.insert($0.urn).inserted })
        updateShuffleOrder()
        nextPageURL = page.nextURL
    }

    mutating func replaceLikes(_ likes: [SoundCloudTrack]) {
        guard source == .likes else { return }
        let likedURNs = Set(likes.map(\.urn))
        let additions = (addedLikesTracks ?? []).filter { !likedURNs.contains($0.urn) }
        tracks = ordered((likes + additions).filter { !(removedURNs?.contains($0.urn) ?? false) },
                         by: reorderedLikesURNs)
        updateShuffleOrder()
    }

    func resolvedTracks(likes: [SoundCloudTrack]) -> [SoundCloudTrack] {
        var resolved = self
        resolved.replaceLikes(likes)
        return resolved.playbackTracks
    }

    var isShuffled: Bool { shuffleEnabled ?? !shuffledURNs.isEmpty }

    var playbackTracks: [SoundCloudTrack] {
        ordered(tracks, by: isShuffled ? shuffledURNs : nil)
    }

    func withoutLikesMetadata() -> TrackQueue {
        var saved = self
        if source == .likes { saved.tracks = [] }
        return saved
    }

    private func ordered(_ tracks: [SoundCloudTrack], by urns: [String]?) -> [SoundCloudTrack] {
        guard let urns else { return tracks }
        let byURN = Dictionary(tracks.map { ($0.urn, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(urns)
        return urns.compactMap { byURN[$0] } + tracks.filter { !known.contains($0.urn) }
    }

    private mutating func updateShuffleOrder() {
        guard isShuffled else { return }
        shuffledURNs = playbackTracks.map(\.urn)
    }

    /// The destination is an insertion offset in the original list, as used by List.onMove.
    @discardableResult
    mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) -> Bool {
        guard !offsets.isEmpty, offsets.allSatisfy({ tracks.indices.contains($0) }),
              (0...tracks.count).contains(destination) else { return false }
        let current = playbackTracks
        let moving = offsets.map { current[$0] }
        var reordered = current.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: insertion)
        guard reordered != current else { return false }
        if isShuffled {
            shuffledURNs = reordered.map(\.urn)
        } else {
            tracks = reordered
            if source == .likes {
                reorderedLikesURNs = tracks.map(\.urn)
            }
        }
        return true
    }

    mutating func setShuffle(_ enabled: Bool, currentURN: String?) {
        guard enabled != isShuffled else { return }
        shuffleEnabled = enabled
        guard enabled else {
            shuffledURNs = []
            return
        }
        shuffledURNs = tracks.map(\.urn).filter { $0 != currentURN }.shuffled()
        if let currentURN, tracks.contains(where: { $0.urn == currentURN }) {
            shuffledURNs.insert(currentURN, at: 0)
        }
    }

    func needsNextPage(after urn: String?) -> Bool {
        nextPageURL != nil && (tracks.isEmpty || tracks.last?.urn == urn)
    }

    func relativeTrack(to urn: String?, offset: Int, wraps: Bool = true) -> SoundCloudTrack? {
        let ordered = playbackTracks
        guard !ordered.isEmpty else { return nil }
        let index = ordered.firstIndex { $0.urn == urn } ?? (offset > 0 ? -1 : 0)
        let destination = index + offset
        guard wraps || ordered.indices.contains(destination) else { return nil }
        return ordered[((destination % ordered.count) + ordered.count) % ordered.count]
    }
}
