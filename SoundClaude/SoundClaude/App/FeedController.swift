import Combine
import Foundation

@MainActor
final class FeedController: ObservableObject {
    @Published private(set) var cache = FeedCache()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let client: SoundCloudClient
    private let auth: AuthController
    private let store: FeedCacheStore
    private var accountID: String?
    private var sessionID = UUID()
    private var restoreTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var retryRefresh = true

    init(client: SoundCloudClient, auth: AuthController, store: FeedCacheStore = FeedCacheStore()) {
        self.client = client
        self.auth = auth
        self.store = store
    }

    func restoreCache() async {
        guard case let .signedIn(user) = auth.state else { return }
        let id = user.urn ?? user.permalinkURL.absoluteString
        if accountID == id {
            await restoreTask?.value
            return
        }
        clear()
        accountID = id
        let session = sessionID
        let task = Task { @MainActor in
            // Missing or damaged files are rebuilt from the API.
            let saved = try? await store.load(accountID: id)
            guard sessionID == session else { return }
            cache = saved ?? FeedCache()
            restoreTask = nil
        }
        restoreTask = task
        await task.value
    }

    func load() async { await load(refresh: true) }
    func loadMore() async { await load(refresh: false) }
    func retry() async { await load(refresh: retryRefresh) }

    private func load(refresh: Bool) async {
        await restoreCache()
        if let loadTask {
            await loadTask.value
            return
        }
        guard let accountID, !Task.isCancelled,
              refresh || !cache.hasLoadedPage || cache.nextPageURL != nil else { return }
        let session = sessionID
        isLoading = true
        errorMessage = nil
        retryRefresh = refresh
        let task = Task { @MainActor in
            defer {
                if sessionID == session {
                    loadTask = nil
                    isLoading = false
                }
            }
            do {
                let baseline = cache
                var updated = refresh ? FeedCache() : baseline
                repeat {
                    let url = updated.nextPageURL
                    try checkSession(session)
                    let token = try await auth.validAccessToken()
                    try checkSession(session)
                    let page = try await client.feed(accessToken: token, pageURL: url)
                    try checkSession(session)
                    try updated.append(page, requestedURL: url)
                    // The initial load and scrolling fetch one page. Refresh reads
                    // through to the cache before replacing the visible snapshot.
                    if !refresh || baseline.items.isEmpty || updated.mergeTail(from: baseline) {
                        try await store.save(updated, accountID: accountID)
                        try checkSession(session)
                        cache = updated
                        break
                    }
                    try await Task.sleep(for: .milliseconds(350))
                } while updated.nextPageURL != nil
            } catch {
                if sessionID == session, !Task.isCancelled, !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
        }
        loadTask = task
        await task.value
    }

    private func checkSession(_ session: UUID) throws {
        try Task.checkCancellation()
        guard sessionID == session else { throw CancellationError() }
    }

    func clear() {
        loadTask?.cancel()
        restoreTask?.cancel()
        loadTask = nil
        restoreTask = nil
        sessionID = UUID()
        accountID = nil
        cache = FeedCache()
        isLoading = false
        errorMessage = nil
        retryRefresh = true
    }
}
