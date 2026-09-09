import AppKit
import Foundation

// Test doubles keep credentials off disk and let tests hold network responses.
final class KeychainTokenStore {
    var record: TokenRecord?
    var deletes = 0
    var loadError: Error?
    func load() throws -> TokenRecord? {
        if let loadError { throw loadError }
        return record
    }
    func save(_ record: TokenRecord) throws { self.record = record }
    func delete() throws { record = nil; deletes += 1 }
}

enum SoundCloudError: Error { case unauthorized, invalidData, api(String), network }
enum SoundCloudConfiguration {
    static let redirectURI = URL(string: "http://127.0.0.1:32148/callback")!
}

@MainActor
final class SoundCloudClient {
    var pendingUser: CheckedContinuation<SoundCloudUser, Error>?
    var pendingRefresh: CheckedContinuation<OAuthTokenResponse, Error>?
    var userToken: String?
    var refreshCount = 0
    func currentUser(accessToken: String) async throws -> SoundCloudUser {
        userToken = accessToken
        return try await withCheckedThrowingContinuation { pendingUser = $0 }
    }
    func refreshToken(_ token: String) async throws -> OAuthTokenResponse {
        refreshCount += 1
        return try await withCheckedThrowingContinuation { pendingRefresh = $0 }
    }
    func signOut(accessToken: String) async throws {}
    func authorizationURL(state: String, challenge: String) async throws -> URL {
        throw SoundCloudError.invalidData
    }
    func exchangeCode(_ code: String, verifier: String) async throws -> OAuthTokenResponse {
        throw SoundCloudError.invalidData
    }
}

@main
struct AuthRestoreTests {
    @MainActor
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("Timed out waiting for session work")
    }

    @MainActor
    static func main() async throws {
        let user = SoundCloudUser(urn: "user:1", username: "Cached", avatarURL: nil,
                                 permalinkURL: URL(string: "https://soundcloud.com/test")!)
        let updated = SoundCloudUser(urn: user.urn, username: "Updated", avatarURL: nil,
                                     permalinkURL: user.permalinkURL)
        func record(expired: Bool = false, cached: Bool = true) -> TokenRecord {
            TokenRecord(accessToken: "saved", refreshToken: "refresh",
                        expiresAt: Date().addingTimeInterval(expired ? -100 : 3600),
                        user: cached ? user : nil)
        }
        func setup(_ record: TokenRecord?) -> (AuthController, SoundCloudClient, KeychainTokenStore) {
            let store = KeychainTokenStore()
            store.record = record
            let client = SoundCloudClient()
            return (AuthController(client: client, tokenStore: store), client, store)
        }

        let (emptyAuth, _, _) = setup(nil)
        precondition(emptyAuth.state == .signedOut)
        await emptyAuth.restore()
        precondition(emptyAuth.state == .signedOut)

        let failedStore = KeychainTokenStore()
        failedStore.loadError = SoundCloudError.invalidData
        let failedAuth = AuthController(client: SoundCloudClient(), tokenStore: failedStore)
        guard case .failed = failedAuth.state else { fatalError("Expected Keychain error") }
        await failedAuth.restore()
        guard case .failed = failedAuth.state else { fatalError("Lost Keychain error") }
        precondition(failedStore.deletes == 0)

        // The first view has the cached identity, with no intermediate signed-out or loading state.
        let (auth, client, store) = setup(record())
        precondition(auth.state == .signedIn(user))
        precondition(client.userToken == nil && client.refreshCount == 0)
        var launchStates: [AuthController.State] = []
        let observation = auth.$state.sink { launchStates.append($0) }
        await auth.restore()
        precondition(launchStates.allSatisfy { $0 == .signedIn(user) })
        observation.cancel()
        precondition(auth.state == .signedIn(user))
        await until { client.pendingUser != nil }
        precondition(client.refreshCount == 0 && client.userToken == "saved")
        client.pendingUser!.resume(returning: updated)
        await until { auth.state == .signedIn(updated) }
        precondition(store.record?.user == updated)

        // A network failure keeps both the visible account and saved credentials.
        let (offlineAuth, offlineClient, offlineStore) = setup(record())
        await offlineAuth.restore()
        await until { offlineClient.pendingUser != nil }
        offlineClient.pendingUser!.resume(throwing: SoundCloudError.network)
        for _ in 0..<100 { await Task.yield() }
        precondition(offlineAuth.state == .signedIn(user) && offlineStore.deletes == 0)
        precondition(offlineStore.record != nil)

        // Expired credentials do not delay the interface; concurrent callers share refresh.
        let (expiredAuth, expiredClient, expiredStore) = setup(record(expired: true))
        precondition(expiredAuth.state == .signedIn(user))
        await expiredAuth.restore()
        precondition(expiredAuth.state == .signedIn(user))
        await until { expiredClient.pendingRefresh != nil }
        let access = Task { try await expiredAuth.validAccessToken() }
        let response = try JSONDecoder().decode(OAuthTokenResponse.self, from: Data(
            #"{"access_token":"new","refresh_token":"rotated","expires_in":3600}"#.utf8))
        expiredClient.pendingRefresh!.resume(returning: response)
        let accessToken = try await access.value
        precondition(accessToken == "new" && expiredClient.refreshCount == 1)
        await until { expiredClient.pendingUser != nil }
        precondition(expiredClient.userToken == "new" && expiredStore.record?.refreshToken == "rotated")
        expiredClient.pendingUser!.resume(returning: user)

        // Confirmed rejection clears saved credentials.
        let (rejectedAuth, rejectedClient, rejectedStore) = setup(record())
        await rejectedAuth.restore()
        await until { rejectedClient.pendingUser != nil }
        rejectedClient.pendingUser!.resume(throwing: SoundCloudError.unauthorized)
        await until { if case .failed = rejectedAuth.state { return true }; return false }
        precondition(rejectedStore.record == nil && rejectedStore.deletes == 1)

        // Refresh failures follow the same credential retention rules.
        for unauthorized in [false, true] {
            let (refreshAuth, refreshClient, refreshStore) = setup(record(expired: true))
            await refreshAuth.restore()
            precondition(refreshAuth.state == .signedIn(user))
            await until { refreshClient.pendingRefresh != nil }
            refreshClient.pendingRefresh!.resume(throwing:
                unauthorized ? SoundCloudError.unauthorized : SoundCloudError.network)
            if unauthorized {
                await until { if case .failed = refreshAuth.state { return true }; return false }
                precondition(refreshStore.record == nil)
            } else {
                for _ in 0..<100 { await Task.yield() }
                precondition(refreshAuth.state == .signedIn(user) && refreshStore.record != nil)
            }
            precondition(refreshClient.pendingUser == nil)
        }

        let (legacyAuth, legacyClient, legacyStore) = setup(record(cached: false))
        precondition(legacyAuth.state == .restoring)
        let legacyRestore = Task { await legacyAuth.restore() }
        await until { legacyClient.pendingUser != nil }
        precondition(legacyAuth.state == .restoring)
        legacyClient.pendingUser!.resume(throwing: SoundCloudError.network)
        await legacyRestore.value
        guard case .failed = legacyAuth.state else { fatalError("Expected restore failure") }
        precondition(legacyStore.record != nil && legacyStore.deletes == 0)

        // A late response cannot undo sign-out or save the old account again.
        let (cancelledAuth, cancelledClient, cancelledStore) = setup(record())
        await cancelledAuth.restore()
        await until { cancelledClient.pendingUser != nil }
        await cancelledAuth.signOut()
        cancelledClient.pendingUser!.resume(returning: updated)
        for _ in 0..<100 { await Task.yield() }
        precondition(cancelledAuth.state == .signedOut && cancelledStore.record == nil)
        let (refreshCancelledAuth, refreshCancelledClient, refreshCancelledStore) = setup(record(expired: true))
        await refreshCancelledAuth.restore()
        await until { refreshCancelledClient.pendingRefresh != nil }
        await refreshCancelledAuth.signOut()
        refreshCancelledClient.pendingRefresh!.resume(returning: response)
        for _ in 0..<100 { await Task.yield() }
        precondition(refreshCancelledAuth.state == .signedOut && refreshCancelledStore.record == nil)
        precondition(refreshCancelledClient.pendingUser == nil)
        print("Auth restore checks passed")
    }
}
