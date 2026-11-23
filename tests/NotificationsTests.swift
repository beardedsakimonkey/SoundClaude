import Foundation

@main
struct NotificationsTests {
    static func main() async throws {
        let me = APITestSupport.meJSON
        let fan = """
            {"urn":"soundcloud:users:7","username":"Fan","verified":true,
             "avatar_url":"https://i1.sndcdn.com/fan.jpg",
             "permalink_url":"https://soundcloud.com/fan"}
            """
        let track = """
            {"id":1,"urn":"soundcloud:tracks:1","title":"My Track","policy":"ALLOW",
             "permalink_url":"https://soundcloud.com/me/my-track","user":\(me)}
            """
        let album = """
            {"id":5,"title":"My Album","is_album":true,"track_count":3,
             "permalink_url":"https://soundcloud.com/me/sets/my-album","user":\(me)}
            """
        // Shaped like api-v2 /activities: the comment omits its user, which is the activity's.
        let comment = """
            {"created_at":"2026-11-20T20:10:24Z","body":"@me nice","id":2619583845,
             "kind":"comment","timestamp":80817,"track_id":1,"track":\(track)}
            """
        func activity(_ type: String, _ fields: String, uuid: String? = "u-\(UUID())") -> String {
            """
            {"type":"\(type)","created_at":"2026-11-20T20:10:24Z",\(uuid.map { "\"uuid\":\"\($0)\"," } ?? "")
             "user":\(fan),\(fields)}
            """
        }

        let decoder = JSONDecoder()
        func decode(_ json: String) throws -> SoundCloudNotification? {
            try decoder.decode(RawNotification.self, from: Data(json.utf8)).notification
        }

        let expectedDate = ISO8601DateFormatter().date(from: "2026-11-20T20:10:24Z")
        for (type, kind) in [("track-like", SoundCloudNotification.Kind.like), ("track-repost", .repost)] {
            let decoded = try decode(activity(type, #""track":\#(track)"#, uuid: "id-1"))!
            precondition(decoded.kind == kind && decoded.id == "id-1")
            precondition(decoded.user.username == "Fan" && decoded.user.isVerified == true)
            precondition(decoded.createdAt == expectedDate)
            guard case let .track(value) = decoded.content else { fatalError("Track was not decoded") }
            precondition(value.title == "My Track" && decoded.comment == nil)
        }
        for (type, kind) in [("playlist-like", SoundCloudNotification.Kind.like), ("playlist-repost", .repost)] {
            let decoded = try decode(activity(type, #""playlist":\#(album)"#))!
            precondition(decoded.kind == kind)
            guard case let .playlist(value) = decoded.content else { fatalError("Playlist was not decoded") }
            precondition(value.title == "My Album" && value.isAlbum == true)
        }
        for (type, kind) in [("comment", SoundCloudNotification.Kind.comment), ("mention", .mention)] {
            let decoded = try decode(activity(type, #""comment":\#(comment)"#))!
            precondition(decoded.kind == kind)
            precondition(decoded.comment?.body == "@me nice")
            precondition(decoded.comment?.urn == "soundcloud:comments:2619583845")
            guard case let .track(value) = decoded.content else { fatalError("Comment track was not decoded") }
            precondition(value.urn == "soundcloud:tracks:1")
        }
        let follow = try decode(activity("affiliation", #""cursor":"x""#))!
        precondition(follow.kind == .follow && follow.content == nil && follow.comment == nil)

        // A comment on a removed track still shows, without a link.
        let orphan = try decode(activity("comment", #""comment":{"id":3,"body":"hi"}"#))!
        precondition(orphan.content == nil && orphan.comment?.body == "hi")

        // Without a uuid, distinct notifications still get distinct IDs.
        let first = try decode(activity("track-like", #""track":\#(track)"#, uuid: nil))!
        let second = try decode(activity("track-repost", #""track":\#(track)"#, uuid: nil))!
        precondition(first.id != second.id)

        // Unknown types, removed content, and missing users are dropped, not fatal.
        for json in [
            activity("track-sharing", #""track":\#(track)"#),
            activity("track-like", #""track":null"#),
            activity("playlist-like", #""playlist":{}"#),
            activity("comment", #""comment":null"#),
            #"{"type":"affiliation","user":null}"#,
            #"{"type":"affiliation","user":{}}"#,
            #"{"user":\#(fan)}"#,
        ] {
            let decoded = try decode(json)
            precondition(decoded == nil, json)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIStubURLProtocol.self]
        let client = SoundCloudClient(
            configuration: APITestSupport.configuration,
            sessionConfiguration: configuration
        )
        let next = "https://api-v2.soundcloud.com/activities/comments?offset=abc&limit=20"
        let paths: [NotificationFilter: String] = [
            .all: "/activities", .likes: "/activities/likes", .reposts: "/activities/reposts",
            .comments: "/activities/comments", .follows: "/activities/follows",
        ]
        precondition(paths.count == NotificationFilter.allCases.count)
        for (filter, expectedPath) in paths {
            APIStubURLProtocol.respond { request in
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                precondition(components.path == expectedPath, components.path)
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
                precondition(query["limit"] == "20" && query["linked_partitioning"] == "1")
                return (200, """
                    {"collection":[\(activity("affiliation", #""cursor":"x""#)),\(activity("unknown", #""x":1"#))],
                     "next_href":"\(next)","query_urn":null}
                    """)
            }
            let page = try await client.notifications(filter: filter, accessToken: "test-token")
            precondition(page.notifications.count == 1 && page.notifications[0].kind == .follow)
            precondition(page.nextURL?.absoluteString == next)
        }

        APIStubURLProtocol.respond { request in
            precondition(request.url?.query?.contains("offset=abc") == true)
            return (200, #"{"collection":[],"next_href":null}"#)
        }
        let last = try await client.notifications(
            filter: .comments, accessToken: "test-token", pageURL: URL(string: next)!
        )
        precondition(last.notifications.isEmpty && last.nextURL == nil)

        // A next page off api-v2 is refused rather than followed.
        APIStubURLProtocol.respond { _ in
            (200, #"{"collection":[],"next_href":"https://example.com/activities"}"#)
        }
        do {
            _ = try await client.notifications(filter: .all, accessToken: "test-token")
            fatalError("Foreign next page was accepted")
        } catch SoundCloudError.unexpectedURL {}

        print("Notification decoding and request checks passed")
    }
}
