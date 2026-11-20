import Foundation

@MainActor
final class AuthController: ObservableObject {
    enum State: Equatable {
        case signedOut
        case restoring
        case signingIn
        case signedIn(SoundCloudUser)
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut
    /// Accounts signed out of on this Mac, most recent first; never the active account.
    @Published private(set) var savedAccounts: [SoundCloudUser] = []

    private let client: SoundCloudClient
    private let tokenStore: KeychainTokenStore
    private var token: TokenRecord?
    /// Loaded only once the signed-out screen needs it, so launch reads one Keychain item.
    private var savedRecords: [TokenRecord]?
    private var restoreTask: Task<Void, Never>?

    init(
        client: SoundCloudClient,
        tokenStore: KeychainTokenStore = KeychainTokenStore()
    ) {
        self.client = client
        self.tokenStore = tokenStore
        // Resolve the local account before SwiftUI builds its first view.
        do {
            token = try tokenStore.load()
            if let token {
                state = token.user.map(State.signedIn) ?? .restoring
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
        if token == nil {
            loadSavedAccounts()
        }
    }

    func restore() async {
        restoreTask?.cancel()
        guard let token else { return }
        if token.user == nil {
            state = .restoring
        }
        let task = Task { @MainActor in
            await validateRestoredSession()
        }
        restoreTask = task
        // Cached accounts can load their library while validation runs.
        if token.user == nil {
            await task.value
        }
    }

    private func validateRestoredSession() async {
        let interval = LaunchMetrics.begin("Session validation")
        defer { LaunchMetrics.end(interval) }
        do {
            try Task.checkCancellation()
            let accessToken = try await validAccessToken()
            try Task.checkCancellation()
            let user = try await client.currentUser(accessToken: accessToken)
            try Task.checkCancellation()
            try saveUser(user)
            state = .signedIn(user)
        } catch {
            guard !Task.isCancelled else { return }
            if case SoundCloudError.unauthorized = error {
                try? tokenStore.delete()
                token = nil
                loadSavedAccounts()
                state = .failed(error.localizedDescription)
            } else if case .signedIn = state {
                // Keep the cached account usable during temporary failures.
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Validates a website session token and saves it only once SoundCloud accepts it.
    func signIn(token accessToken: String) async {
        restoreTask?.cancel()
        restoreTask = nil
        state = .signingIn
        do {
            let user = try await client.currentUser(accessToken: accessToken)
            let record = TokenRecord(accessToken: accessToken, user: user)
            try tokenStore.save(record)
            token = record
            // A fresh token replaces any saved one for the same account.
            updateSavedAccounts { $0.removeAll { $0.user?.accountID == user.accountID } }
            state = .signedIn(user)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Switches to a saved account at once with its cached identity, then validates
    /// it like a launch restore: a 401 discards the token and returns to sign-in.
    func signIn(savedAccount user: SoundCloudUser) async {
        guard let record = savedRecords?.first(where: { $0.user?.accountID == user.accountID }),
              let cachedUser = record.user else { return }
        restoreTask?.cancel()
        restoreTask = nil
        do {
            try tokenStore.save(record)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        token = record
        updateSavedAccounts { $0.removeAll { $0.user?.accountID == user.accountID } }
        state = .signedIn(cachedUser)
        await restore()
    }

    func forgetSavedAccount(_ user: SoundCloudUser) {
        updateSavedAccounts { $0.removeAll { $0.user?.accountID == user.accountID } }
    }

    /// Keeps the session token as a saved account so signing back in needs no new token.
    /// SoundCloud is not told, so the token stays valid until it is forgotten.
    func signOut() async {
        restoreTask?.cancel()
        restoreTask = nil
        if let record = token, let user = record.user {
            updateSavedAccounts {
                $0.removeAll { $0.user?.accountID == user.accountID }
                $0.insert(record, at: 0)
            }
        } else {
            loadSavedAccounts()
        }
        token = nil
        try? tokenStore.delete()
        state = .signedOut
    }

    /// Website sessions do not expire on a schedule; a 401 means the user must sign in again.
    func validAccessToken() async throws -> String {
        guard let record = token else {
            throw SoundCloudError.unauthorized
        }
        return record.accessToken
    }

    private func loadSavedAccounts() {
        updateSavedAccounts { _ in }
    }

    /// Saved accounts are a convenience: Keychain failures leave them unchanged rather
    /// than blocking sign-in, and an unreadable list is never overwritten.
    private func updateSavedAccounts(_ change: (inout [TokenRecord]) -> Void) {
        do {
            var records = try savedRecords ?? tokenStore.loadSavedAccounts()
            let original = records
            change(&records)
            if records != original {
                try tokenStore.saveSavedAccounts(records)
            }
            savedRecords = records
        } catch {}
        savedAccounts = (savedRecords ?? []).compactMap(\.user)
    }

    private func saveUser(_ user: SoundCloudUser) throws {
        guard var record = token else { throw SoundCloudError.unauthorized }
        record.user = user
        token = record
        try tokenStore.save(record)
    }
}
