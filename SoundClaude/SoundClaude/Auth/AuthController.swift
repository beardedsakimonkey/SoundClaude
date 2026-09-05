import AppKit
import CryptoKit
import Foundation
import Security

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
    private var refreshTask: Task<String, Error>?
    private var callbackServer: OAuthCallbackServer?

    init(
        client: SoundCloudClient,
        tokenStore: KeychainTokenStore = KeychainTokenStore()
    ) {
        self.client = client
        self.tokenStore = tokenStore
    }

    func restore() async {
        state = .restoring
        do {
            guard let savedToken = try tokenStore.load() else {
                state = .signedOut
                return
            }
            token = savedToken
            let accessToken = try await validAccessToken()
            let user = try await client.currentUser(accessToken: accessToken)
            try saveUser(user)
            state = .signedIn(user)
        } catch {
            try? tokenStore.delete()
            token = nil
            state = .failed(error.localizedDescription)
        }
    }

    func signIn() async {
        guard callbackServer == nil else { return }
        state = .signingIn

        do {
            let verifier = try randomURLSafeValue(byteCount: 64)
            let stateValue = try randomURLSafeValue(byteCount: 32)
            let challenge = Self.base64URL(
                Data(SHA256.hash(data: Data(verifier.utf8)))
            )
            let server = OAuthCallbackServer(expectedState: stateValue)
            callbackServer = server
            try await server.start()

            let authorizationURL = try await client.authorizationURL(
                state: stateValue,
                challenge: challenge
            )
            guard NSWorkspace.shared.open(authorizationURL) else {
                throw SoundCloudError.api(
                    "The system browser could not open SoundCloud sign-in."
                )
            }

            let code = try await server.waitForCode()
            callbackServer = nil
            let response = try await client.exchangeCode(
                code,
                verifier: verifier
            )
            guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
                throw SoundCloudError.invalidData
            }
            let record = TokenRecord(
                accessToken: response.accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(response.expiresIn),
                user: nil
            )
            token = record
            try tokenStore.save(record)

            let user = try await client.currentUser(
                accessToken: response.accessToken
            )
            try saveUser(user)
            state = .signedIn(user)
        } catch {
            callbackServer?.cancel()
            callbackServer = nil
            state = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        refreshTask?.cancel()
        refreshTask = nil
        callbackServer?.cancel()
        callbackServer = nil
        let accessToken = token?.accessToken
        token = nil
        try? tokenStore.delete()
        state = .signedOut
        if let accessToken {
            try? await client.signOut(accessToken: accessToken)
        }
    }

    func validAccessToken() async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let record = token else {
            throw SoundCloudError.unauthorized
        }
        guard record.expiresAt.timeIntervalSinceNow <= 60 else {
            return record.accessToken
        }

        let task = Task { @MainActor in
            defer {
                // Sign-out clears cancelled tasks. They must not clear a newer task.
                if !Task.isCancelled {
                    refreshTask = nil
                }
            }
            try Task.checkCancellation()
            let response = try await client.refreshToken(record.refreshToken)
            try Task.checkCancellation()
            guard let refreshToken = response.refreshToken,
                  !refreshToken.isEmpty else {
                throw SoundCloudError.invalidData
            }
            let refreshedRecord = TokenRecord(
                accessToken: response.accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(response.expiresIn),
                user: record.user
            )
            token = refreshedRecord
            try tokenStore.save(refreshedRecord)
            return refreshedRecord.accessToken
        }
        refreshTask = task
        return try await task.value
    }

    private func saveUser(_ user: SoundCloudUser) throws {
        guard var record = token else { throw SoundCloudError.unauthorized }
        record.user = user
        token = record
        try tokenStore.save(record)
    }

    private func randomURLSafeValue(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            byteCount,
            &bytes
        )
        guard status == errSecSuccess else {
            throw SoundCloudError.api("Secure random data is unavailable.")
        }
        return Self.base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
