import Foundation

@main
struct FollowingTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FollowingURLProtocol.self]
        let client = SoundCloudClient(
            configuration: SoundCloudConfiguration(clientID: "test", clientSecret: "test"),
            sessionConfiguration: configuration
        )
        FollowingURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            precondition(request.url?.path == "/me/followings")
            if request.url?.query == "limit=200" {
                return (200, #"{"collection":[{"urn":"soundcloud:users:1"}],"next_href":"https://api.soundcloud.com/me/followings?cursor=next"}"#)
            }
            precondition(request.url?.query == "cursor=next")
            return (200, #"{"collection":[{"urn":"soundcloud:users:2"}],"next_href":null}"#)
        }
        let followed = try await client.followedArtistURNs(accessToken: "test-token")
        precondition(followed == ["soundcloud:users:1", "soundcloud:users:2"])
        precondition(!followed.contains("soundcloud:users:3"))

        FollowingURLProtocol.respond { _ in (200, #"{"collection":[]}"#) }
        let empty = try await client.followedArtistURNs(accessToken: "test-token")
        precondition(empty.isEmpty)

        for isFollowed in [true, false] {
            FollowingURLProtocol.respond { request in
                precondition(request.httpMethod == (isFollowed ? "PUT" : "DELETE"))
                precondition(request.url?.path == "/me/followings/soundcloud:users:1")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                return (isFollowed ? 201 : 200, "")
            }
            try await client.setArtistFollowed(urn: "soundcloud:users:1", isFollowed: isFollowed, accessToken: "test-token")
        }
        FollowingURLProtocol.respond { _ in (401, "{}") }
        do {
            _ = try await client.followedArtistURNs(accessToken: "test-token")
            fatalError("Unauthorized response was accepted")
        } catch SoundCloudError.unauthorized {}
        FollowingURLProtocol.respond { _ in (422, #"{"message":"Follow limit reached"}"#) }
        do {
            try await client.setArtistFollowed(urn: "soundcloud:users:1", isFollowed: true, accessToken: "test-token")
            fatalError("Failed follow was accepted")
        } catch SoundCloudError.api(let message) {
            precondition(message == "Follow limit reached")
        }
        FollowingURLProtocol.respond { _ in (429, "{}") }
        do {
            _ = try await client.followedArtistURNs(accessToken: "test-token")
            fatalError("Rate limit was accepted as an empty list")
        } catch SoundCloudError.rateLimited {}
        FollowingURLProtocol.respond { request in
            (200, "{\"collection\":[],\"next_href\":\"\(request.url!.absoluteString)\"}")
        }
        do {
            _ = try await client.followedArtistURNs(accessToken: "test-token")
            fatalError("Repeated page was accepted")
        } catch SoundCloudError.invalidData {}
        FollowingURLProtocol.respond { _ in
            (200, #"{"collection":[],"next_href":"https://example.com/next"}"#)
        }
        do {
            _ = try await client.followedArtistURNs(accessToken: "test-token")
            fatalError("Untrusted page was accepted")
        } catch SoundCloudError.unexpectedURL {}
        FollowingURLProtocol.respond { _ in (200, #"{"collection":[{}]}"#) }
        do {
            _ = try await client.followedArtistURNs(accessToken: "test-token")
            fatalError("Missing user URN was ignored")
        } catch SoundCloudError.invalidData {}
        for list in ArtistUserList.allCases {
            let nextURL = URL(string: "https://api.soundcloud.com/users/soundcloud:users:1/\(list.rawValue)?cursor=next")!
            FollowingURLProtocol.respond { request in
                precondition(request.httpMethod == "GET")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                precondition(request.url?.path == "/users/soundcloud:users:1/\(list.rawValue)")
                if request.url == nextURL {
                    return (200, #"{"collection":[{"urn":"soundcloud:users:3","username":"Second","permalink_url":"https://soundcloud.com/second"}],"next_href":null}"#)
                }
                precondition(request.url?.query == "limit=50")
                return (200, """
                    {"collection":[
                        {"urn":"soundcloud:users:2","username":"First","permalink_url":"https://soundcloud.com/first","avatar_url":"https://i1.sndcdn.com/avatar-large.jpg"},
                        {"urn":"soundcloud:users:invalid"}
                    ],"next_href":"\(nextURL.absoluteString)"}
                    """)
            }
            let first = try await client.artistUsers(urn: "soundcloud:users:1", list: list, accessToken: "test-token")
            precondition(first.users.map(\.username) == ["First"])
            precondition(first.users.first?.avatarURL != nil)
            precondition(first.nextURL == nextURL)
            let last = try await client.artistUsers(urn: "soundcloud:users:1", list: list, accessToken: "test-token", pageURL: first.nextURL)
            precondition(last.users.map(\.username) == ["Second"] && last.nextURL == nil)
        }
        FollowingURLProtocol.respond { _ in (200, #"{"collection":[]}"#) }
        let users = try await client.artistUsers(urn: "soundcloud:users:1", list: .followers, accessToken: "test-token")
        precondition(users.users.isEmpty && users.nextURL == nil)
        FollowingURLProtocol.respond { _ in (200, #"{"collection":[],"next_href":"https://example.com/users"}"#) }
        do {
            _ = try await client.artistUsers(urn: "soundcloud:users:1", list: .followers, accessToken: "test-token")
            fatalError("Unsafe pagination URL was accepted")
        } catch SoundCloudError.unexpectedURL {}
        FollowingURLProtocol.respond { _ in (429, "{}") }
        do {
            _ = try await client.artistUsers(urn: "soundcloud:users:1", list: .following, accessToken: "test-token")
            fatalError("Rate limit was accepted as an empty user list")
        } catch SoundCloudError.rateLimited {}
        print("Following API checks passed")
    }
}

private final class FollowingURLProtocol: URLProtocol {
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
