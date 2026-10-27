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

    private let client: SoundCloudClient
    private let tokenStore: KeychainTokenStore
    private var token: TokenRecord?
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
            state = .signedIn(user)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        restoreTask?.cancel()
        restoreTask = nil
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

    private func saveUser(_ user: SoundCloudUser) throws {
        guard var record = token else { throw SoundCloudError.unauthorized }
        record.user = user
        token = record
        try tokenStore.save(record)
    }
}
