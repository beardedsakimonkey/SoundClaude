import Foundation

@MainActor
final class AuthController {
    enum State { case signedIn(SoundCloudUser), signedOut }
    var state: State = .signedIn(user)
    func validAccessToken() async throws -> String { "test" }
}

@MainActor
final class SoundCloudClient {
    var requests: [URL?] = []
    var fetch: (URL?) async throws -> SoundCloudFeedPage = { _ in
        SoundCloudFeedPage(items: [], nextURL: nil)
    }
    func feed(accessToken: String, pageURL: URL?) async throws -> SoundCloudFeedPage {
        requests.append(pageURL)
        return try await fetch(pageURL)
    }
}

enum SoundCloudError: Error { case invalidData }

let user = SoundCloudUser(urn: "user:1", username: "Test", avatarURL: nil,
                         permalinkURL: URL(string: "https://soundcloud.com/test")!)
func item(_ id: Int, repost: Bool = false, playlist: Bool = false) -> SoundCloudFeedItem {
    let content: SoundCloudFeedContent = playlist
        ? .playlist(SoundCloudPlaylist(urn: "playlist:\(id)", title: "Playlist \(id)", owner: user,
            artworkURL: nil, permalinkURL: user.permalinkURL, description: nil,
            trackCount: 2, durationMilliseconds: 2000, isPrivate: false))
        : .track(SoundCloudTrack(urn: "track:\(id)", title: "Track \(id)", artist: user,
            artworkURL: nil, waveformURL: nil, permalinkURL: user.permalinkURL,
            durationMilliseconds: 1000, access: .playable, secretToken: nil))
    return SoundCloudFeedItem(content: content, user: user, isRepost: repost,
                             createdAt: Date(timeIntervalSince1970: Double(id)))
}

@main
struct FeedCacheTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FeedCacheStore(directory: directory)
        let next = URL(string: "https://api.soundcloud.com/me/feed?cursor=next")!
        let older = URL(string: "https://api.soundcloud.com/me/feed?cursor=older")!
        let head = URL(string: "https://api.soundcloud.com/me/feed?cursor=head")!
        let baseline = FeedCache(items: [item(4), item(3, repost: true, playlist: true), item(2), item(1)],
                                 nextPageURL: next, hasLoadedPage: true)
        try await store.save(baseline, accountID: "user:1")
        let missing = try await store.load(accountID: "user:2")
        precondition(missing == nil)
        let disk = try await FeedCacheStore(directory: directory).load(accountID: "user:1")
        precondition(disk?.items.map(\.id) == baseline.items.map(\.id) && disk?.nextPageURL == next)
        guard case let .playlist(playlist) = disk?.items[1].content else {
            fatalError("Playlist activity was not restored")
        }
        precondition(playlist.title == "Playlist 3" && disk?.items[1].isRepost == true)
        precondition(disk?.items[0].content.track?.title == "Track 4")

        let auth = AuthController()
        let client = SoundCloudClient()
        let controller = FeedController(client: client, auth: auth, store: store)
        await controller.restoreCache()
        precondition(controller.cache.items.map(\.id) == baseline.items.map(\.id) && client.requests.isEmpty)

        // A failed refresh preserves the visible and persisted snapshot.
        client.fetch = { url in
            if url == nil { return SoundCloudFeedPage(items: [item(6)], nextURL: head) }
            throw SoundCloudError.invalidData
        }
        await controller.load()
        precondition(controller.errorMessage != nil && !controller.isLoading)
        precondition(controller.cache.items.map(\.id) == baseline.items.map(\.id))
        let failed = try await store.load(accountID: "user:1")
        precondition(failed?.items.map(\.id) == baseline.items.map(\.id))

        // Retry starts at the newest page. An overlap retains older items and the cursor.
        client.requests = []
        client.fetch = { url in
            SoundCloudFeedPage(items: url == nil ? [item(6)] : [item(5), item(4)],
                               nextURL: url == nil ? head : older)
        }
        await controller.retry()
        precondition(client.requests == [nil, head])
        precondition(controller.cache.items.map(\.id) == ([item(6), item(5)] + baseline.items).map(\.id))
        precondition(controller.cache.nextPageURL == next)

        // Scrolling resumes from the saved cursor, preserving distinct reposts.
        client.fetch = { url in
            precondition(url == next)
            return SoundCloudFeedPage(items: [item(1), item(1, repost: true), item(0)], nextURL: older)
        }
        await controller.loadMore()
        precondition(controller.cache.items.suffix(3).map(\.id) == [item(1), item(1, repost: true), item(0)].map(\.id))
        controller.clear()
        await controller.restoreCache()
        precondition(controller.cache.nextPageURL == older && controller.cache.loadedPageURLs.contains(next))

        // Pagination cycles remain detectable after restarting.
        client.fetch = { _ in SoundCloudFeedPage(items: [item(-1)], nextURL: next) }
        await controller.loadMore()
        precondition(controller.errorMessage != nil && controller.cache.nextPageURL == older)
        client.fetch = { url in
            precondition(url == older)
            return SoundCloudFeedPage(items: [item(-1)], nextURL: nil)
        }
        await controller.retry()
        precondition(controller.errorMessage == nil && controller.cache.nextPageURL == nil)
        precondition(controller.cache.items.last?.id == item(-1).id)

        // A complete refresh detects removals, including an empty remote feed.
        client.fetch = { _ in SoundCloudFeedPage(items: [item(7)], nextURL: nil) }
        await controller.load()
        precondition(controller.cache.items.map(\.id) == [item(7).id])
        client.fetch = { _ in SoundCloudFeedPage(items: [], nextURL: nil) }
        await controller.load()
        precondition(controller.cache.items.isEmpty && controller.cache.hasLoadedPage)

        // Another account imports only one page and restores it after sign-out.
        auth.state = .signedIn(SoundCloudUser(urn: "user:2", username: "Other", avatarURL: nil,
                                            permalinkURL: user.permalinkURL))
        await controller.restoreCache()
        precondition(!controller.cache.hasLoadedPage)
        client.requests = []
        client.fetch = { _ in SoundCloudFeedPage(items: [item(10)], nextURL: next) }
        await controller.load()
        precondition(client.requests.count == 1 && controller.cache.nextPageURL == next)
        controller.clear()
        await controller.restoreCache()
        precondition(controller.cache.items.map(\.id) == [item(10).id])

        // Concurrent callers share a request; old responses cannot cross sign-out.
        var response: CheckedContinuation<SoundCloudFeedPage, Never>?
        client.fetch = { _ in await withCheckedContinuation { response = $0 } }
        let count = client.requests.count
        let first = Task { await controller.loadMore() }
        while response == nil { await Task.yield() }
        let second = Task { await controller.loadMore() }
        for _ in 0..<10 { await Task.yield() }
        precondition(client.requests.count == count + 1)
        controller.clear()
        auth.state = .signedOut
        response?.resume(returning: SoundCloudFeedPage(items: [item(99)], nextURL: nil))
        await first.value
        await second.value
        precondition(controller.cache.items.isEmpty && !controller.isLoading)
        let afterSignOut = try await store.load(accountID: "user:2")
        precondition(afterSignOut?.items.map(\.id) == [item(10).id])

        // Damaged files are rebuilt from the next successful response.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files { try Data("broken".utf8).write(to: file) }
        auth.state = .signedIn(user)
        client.fetch = { _ in SoundCloudFeedPage(items: [item(8)], nextURL: nil) }
        await controller.load()
        let repaired = try await store.load(accountID: "user:1")
        precondition(repaired?.items.map(\.id) == [item(8).id])
        print("Feed persistence, refresh, pagination, and account isolation checks passed")
    }
}
