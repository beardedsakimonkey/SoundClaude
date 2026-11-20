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
    var saved: [TokenRecord] = []
    var savedLoads = 0
    var savedLoadError: Error?
    func loadSavedAccounts() throws -> [TokenRecord] {
        savedLoads += 1
        if let savedLoadError { throw savedLoadError }
        return saved
    }
    func saveSavedAccounts(_ records: [TokenRecord]) throws { saved = records }
}

enum SoundCloudError: Error { case unauthorized, invalidData, api(String), network }
@MainActor
final class SoundCloudClient {
    var pendingUser: CheckedContinuation<SoundCloudUser, Error>?
    var userToken: String?
    func currentUser(accessToken: String) async throws -> SoundCloudUser {
        userToken = accessToken
        return try await withCheckedThrowingContinuation { pendingUser = $0 }
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
        func record(cached: Bool = true) -> TokenRecord {
            TokenRecord(accessToken: "saved", user: cached ? user : nil)
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
        precondition(client.userToken == nil)
        var launchStates: [AuthController.State] = []
        let observation = auth.$state.sink { launchStates.append($0) }
        await auth.restore()
        precondition(launchStates.allSatisfy { $0 == .signedIn(user) })
        observation.cancel()
        precondition(auth.state == .signedIn(user))
        await until { client.pendingUser != nil }
        precondition(client.userToken == "saved")
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

        // Confirmed rejection clears saved credentials.
        let (rejectedAuth, rejectedClient, rejectedStore) = setup(record())
        await rejectedAuth.restore()
        await until { rejectedClient.pendingUser != nil }
        rejectedClient.pendingUser!.resume(throwing: SoundCloudError.unauthorized)
        await until { if case .failed = rejectedAuth.state { return true }; return false }
        precondition(rejectedStore.record == nil && rejectedStore.deletes == 1)

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

        // Website tokens are saved only after SoundCloud accepts them.
        let (signInAuth, signInClient, signInStore) = setup(nil)
        let signIn = Task { await signInAuth.signIn(token: "website") }
        await until { signInClient.pendingUser != nil }
        precondition(signInAuth.state == .signingIn && signInClient.userToken == "website")
        precondition(signInStore.record == nil)
        signInClient.pendingUser!.resume(returning: user)
        await signIn.value
        precondition(signInAuth.state == .signedIn(user))
        precondition(signInStore.record == TokenRecord(accessToken: "website", user: user))
        let signedInToken = try await signInAuth.validAccessToken()
        precondition(signedInToken == "website")

        let (rejectedSignInAuth, rejectedSignInClient, rejectedSignInStore) = setup(nil)
        let rejectedSignIn = Task { await rejectedSignInAuth.signIn(token: "expired") }
        await until { rejectedSignInClient.pendingUser != nil }
        rejectedSignInClient.pendingUser!.resume(throwing: SoundCloudError.unauthorized)
        await rejectedSignIn.value
        guard case .failed = rejectedSignInAuth.state else { fatalError("Rejected token signed in") }
        precondition(rejectedSignInStore.record == nil)
        do {
            _ = try await rejectedSignInAuth.validAccessToken()
            fatalError("Rejected token was returned")
        } catch SoundCloudError.unauthorized {}

        // Launching signed in reads only the active session.
        precondition(store.savedLoads == 0)

        // Signing out keeps the token as a saved account, most recent first.
        let other = SoundCloudUser(urn: "user:2", username: "Other", avatarURL: nil,
                                   permalinkURL: URL(string: "https://soundcloud.com/other")!)
        let otherRecord = TokenRecord(accessToken: "other", user: other)
        let (savingAuth, savingClient, savingStore) = setup(record())
        savingStore.saved = [otherRecord]
        await savingAuth.signOut()
        precondition(savingAuth.state == .signedOut && savingStore.record == nil)
        precondition(savingStore.saved == [record(), otherRecord])
        precondition(savingAuth.savedAccounts == [user, other])

        // A saved account signs in at once with its cached identity, then validates.
        await savingAuth.signIn(savedAccount: other)
        precondition(savingAuth.state == .signedIn(other))
        precondition(savingStore.record == otherRecord && savingStore.saved == [record()])
        precondition(savingAuth.savedAccounts == [user])
        await until { savingClient.pendingUser != nil }
        precondition(savingClient.userToken == "other")
        savingClient.pendingUser!.resume(returning: other)
        for _ in 0..<100 { await Task.yield() }
        let switchedToken = try await savingAuth.validAccessToken()
        precondition(switchedToken == "other")

        // An expired saved token is discarded, not saved again.
        savingClient.pendingUser = nil
        await savingAuth.signIn(savedAccount: user)
        await until { savingClient.pendingUser != nil }
        savingClient.pendingUser!.resume(throwing: SoundCloudError.unauthorized)
        await until { if case .failed = savingAuth.state { return true }; return false }
        precondition(savingStore.record == nil && savingStore.saved == [])
        precondition(savingAuth.savedAccounts == [])

        // A signed-out launch lists saved accounts; forgetting removes the token.
        let listStore = KeychainTokenStore()
        listStore.saved = [otherRecord]
        let listedAuth = AuthController(client: SoundCloudClient(), tokenStore: listStore)
        precondition(listedAuth.savedAccounts == [other])
        listedAuth.forgetSavedAccount(other)
        precondition(listStore.saved == [] && listedAuth.savedAccounts == [])

        // A fresh token for a saved account replaces the saved one.
        let freshStore = KeychainTokenStore()
        freshStore.saved = [otherRecord]
        let freshClient = SoundCloudClient()
        let freshAuth = AuthController(client: freshClient, tokenStore: freshStore)
        let freshSignIn = Task { await freshAuth.signIn(token: "fresh") }
        await until { freshClient.pendingUser != nil }
        freshClient.pendingUser!.resume(returning: other)
        await freshSignIn.value
        precondition(freshStore.saved == [] && freshAuth.savedAccounts == [])

        // An unreadable saved list is never overwritten, and sign-out still completes.
        let (lockedAuth, _, lockedStore) = setup(record())
        lockedStore.savedLoadError = SoundCloudError.invalidData
        lockedStore.saved = [otherRecord]
        await lockedAuth.signOut()
        precondition(lockedAuth.state == .signedOut && lockedStore.saved == [otherRecord])
        print("Auth restore checks passed")
    }
}
