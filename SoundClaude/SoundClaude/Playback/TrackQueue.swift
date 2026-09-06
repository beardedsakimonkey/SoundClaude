import Foundation

struct TrackQueue: Codable {
    enum Source: Codable, Equatable {
        case likes
        case artist(String)
        case playlist(String)
        case related(String)
        case single
    }

    let source: Source
    private(set) var tracks: [SoundCloudTrack]
    private(set) var nextPageURL: URL?
    private var loadedPageURLs: Set<URL> = []
    private var shuffledURNs: [String] = []

    init(source: Source, tracks: [SoundCloudTrack], nextPageURL: URL? = nil) {
        self.source = source
        var known = Set<String>()
        self.tracks = tracks.filter { known.insert($0.urn).inserted }
        self.nextPageURL = nextPageURL
    }

    mutating func append(_ page: SoundCloudTrackPage) throws {
        if let next = page.nextURL,
           next == nextPageURL || loadedPageURLs.contains(next) {
            throw SoundCloudError.invalidData
        }
        if let nextPageURL { loadedPageURLs.insert(nextPageURL) }
        var known = Set(tracks.map(\.urn))
        tracks.append(contentsOf: page.tracks.filter { known.insert($0.urn).inserted })
        nextPageURL = page.nextURL
    }

    mutating func replaceLikes(_ likes: [SoundCloudTrack]) {
        guard source == .likes else { return }
        tracks = likes
    }

    mutating func resetShuffle() {
        shuffledURNs = []
    }

    func needsNextPage(after urn: String?) -> Bool {
        nextPageURL != nil && (tracks.isEmpty || tracks.last?.urn == urn)
    }

    mutating func relativeTrack(to urn: String?, offset: Int, shuffle: Bool) -> SoundCloudTrack? {
        guard !tracks.isEmpty else { return nil }
        let ordered: [SoundCloudTrack]
        if shuffle {
            let available = Set(tracks.map(\.urn))
            shuffledURNs.removeAll { !available.contains($0) }
            let existing = Set(shuffledURNs)
            var added = tracks.map(\.urn).filter { !existing.contains($0) }.shuffled()
            if shuffledURNs.isEmpty, let urn, let index = added.firstIndex(of: urn) {
                added.remove(at: index)
                added.insert(urn, at: 0)
            }
            shuffledURNs.append(contentsOf: added)
            let byURN = Dictionary(tracks.map { ($0.urn, $0) }, uniquingKeysWith: { first, _ in first })
            ordered = shuffledURNs.compactMap { byURN[$0] }
        } else {
            ordered = tracks
        }
        let index = ordered.firstIndex { $0.urn == urn } ?? (offset > 0 ? -1 : 0)
        return ordered[(index + offset + ordered.count) % ordered.count]
    }
}
