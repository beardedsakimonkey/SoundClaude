import Foundation

@MainActor
final class AuthController {
    func validAccessToken() async throws -> String { "test-token" }
}

@main
struct RepostsTests {
    @MainActor
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RepostsURLProtocol.self]
        let client = SoundCloudClient(
            configuration: SoundCloudConfiguration(clientID: "test", clientSecret: "test"),
            sessionConfiguration: configuration
        )
        let controller = RepostsController(client: client, auth: AuthController())
        let user = SoundCloudUser(urn: "soundcloud:users:1", username: "Test", avatarURL: nil,
                                  permalinkURL: URL(string: "https://soundcloud.com/test")!)
        var track = SoundCloudTrack(urn: "soundcloud:tracks:1", title: "Test", artist: user,
            artworkURL: nil, waveformURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/test/track")!,
            durationMilliseconds: 1000, access: .playable, secretToken: nil)
        track.repostsCount = 5
        RepostsURLProtocol.respond { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            precondition(request.httpMethod == "GET")
            precondition(request.url?.path == "/me/reposts/tracks")
            if request.url?.query?.contains("cursor=next") == true {
                return (200, #"{"collection":[{"urn":"soundcloud:tracks:1","title":"Test","permalink_url":"https://soundcloud.com/test/track","access":"playable","user":{"username":"Test","permalink_url":"https://soundcloud.com/test"}}],"next_href":null}"#)
            }
            return (200, #"{"collection":[],"next_href":"https://api.soundcloud.com/me/reposts/tracks?cursor=next"}"#)
        }
        try await controller.load()
        precondition(controller.isReposted(track))
        precondition(!controller.isLoading)
        RepostsURLProtocol.respond { request in
            precondition(request.httpMethod == "DELETE")
            precondition(request.url?.path == "/reposts/tracks/soundcloud:tracks:1")
            return (200, "")
        }
        try await controller.toggleRepost(track)
        precondition(!controller.isReposted(track))
        precondition(controller.repostCount(for: track) == 4)
        RepostsURLProtocol.respond { request in
            precondition(request.httpMethod == "POST")
            precondition(request.url?.path == "/reposts/tracks/soundcloud:tracks:1")
            return (201, "")
        }
        try await controller.toggleRepost(track)
        precondition(controller.isReposted(track))
        precondition(controller.repostCount(for: track) == 5)
        RepostsURLProtocol.respond { _ in (401, "{}") }
        do {
            try await controller.toggleRepost(track)
            fatalError("Unauthorized mutation accepted")
        } catch SoundCloudError.unauthorized {}
        precondition(controller.isReposted(track))
        precondition(controller.repostCount(for: track) == 5)
        precondition(controller.updatingTrackURNs.isEmpty)
        controller.clear()
        precondition(!controller.isReposted(track))
        do {
            try await controller.toggleRepost(track)
            fatalError("Failed initial load allowed mutation")
        } catch SoundCloudError.unauthorized {}
        precondition(!controller.isLoading && controller.updatingTrackURNs.isEmpty)
        RepostsURLProtocol.respond { _ in
            (200, #"{"collection":[],"next_href":"https://api.soundcloud.com/me/reposts/tracks?cursor=loop"}"#)
        }
        do {
            try await controller.load()
            fatalError("Repeated cursor accepted")
        } catch SoundCloudError.invalidData {}
        RepostsURLProtocol.respond { _ in (200, #"{"collection":[],"next_href":null}"#) }
        try await controller.load()
        precondition(!controller.isReposted(track))
        print("Repost API and state checks passed")
    }
}

private final class RepostsURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, String))?

    static func respond(_ handler: @escaping (URLRequest) -> (Int, String)) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler!
        Self.lock.unlock()
        let (status, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
