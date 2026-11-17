import Foundation
import Observation

/// Each sort order keeps its own tracks, cursor, and in-flight request.
@MainActor
@Observable
final class ArtistTrackPageState {
    private(set) var tracks: [SoundCloudTrack] = []
    private(set) var nextPageURL: URL?
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private var loadedPageURLs: Set<URL> = []
    private var loadTask: Task<Void, Never>?

    var isLoading: Bool { loadTask != nil }

    private var canLoadMore: Bool { !hasLoaded || nextPageURL != nil }

    var mayHaveTracks: Bool {
        !tracks.isEmpty || (errorMessage == nil && canLoadMore)
    }

    var needsFirstTracks: Bool {
        tracks.isEmpty && mayHaveTracks
    }

    var showsLoadingIndicator: Bool {
        isLoading || (errorMessage == nil && canLoadMore)
    }

    func seed(with page: SoundCloudTrackPage) {
        var seen = Set<String>()
        tracks = page.tracks.filter { seen.insert($0.urn).inserted }
        nextPageURL = page.nextURL
        hasLoaded = true
    }

    func loadNextPage(
        fetch: @escaping @MainActor (URL?) async throws -> SoundCloudTrackPage
    ) async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard !Task.isCancelled, canLoadMore else { return }
        errorMessage = nil
        // A disappearing footer or a quick sort change must not cancel the request
        // and leave the next footer waiting on the same cursor without a task.
        let task = Task {
            defer { loadTask = nil }
            do {
                var knownURNs = Set(tracks.map(\.urn))
                var pagesWithoutNewTracks = 0
                while true {
                    let pageURL = nextPageURL
                    let page = try await fetch(pageURL)
                    try Task.checkCancellation()
                    if let nextURL = page.nextURL,
                       nextURL == pageURL || loadedPageURLs.contains(nextURL) {
                        throw SoundCloudError.invalidData
                    }
                    let additions = page.tracks.filter { knownURNs.insert($0.urn).inserted }
                    tracks.append(contentsOf: additions)
                    if let pageURL { loadedPageURLs.insert(pageURL) }
                    nextPageURL = page.nextURL
                    hasLoaded = true
                    // Empty and duplicate-only pages must advance without relying
                    // on SwiftUI to recreate a footer that is already visible.
                    if !additions.isEmpty || nextPageURL == nil { break }
                    pagesWithoutNewTracks += 1
                    guard pagesWithoutNewTracks < 20 else {
                        throw SoundCloudError.api("SoundCloud returned too many pages without new tracks. Try again.")
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        loadTask = task
        await task.value
    }
}
