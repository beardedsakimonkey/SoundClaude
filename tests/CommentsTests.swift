import Foundation

@main
struct CommentsTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommentsURLProtocol.self]
        let client = SoundCloudClient(
            configuration: APITestSupport.configuration,
            sessionConfiguration: configuration
        )
        let decoder = JSONDecoder()
        func comment(timestamp: String, date: String = "2007/09/11 15:40:24 +0000") -> String {
            """
            {"id":1234,"body":"Great track!\\nSecond line.",
             "created_at":"\(date)","timestamp":\(timestamp),
             "user":{"urn":"soundcloud:users:1","username":"Listener",
                     "permalink_url":"https://soundcloud.com/listener"}}
            """
        }
        for timestamp in ["4960", "\"4960\"", "4960.5", "\"4960.5\""] {
            let decoded = try decoder.decode(SoundCloudComment.self, from: Data(comment(timestamp: timestamp).utf8))
            precondition(decoded.id == "soundcloud:comments:1234")
            precondition(decoded.body == "Great track!\nSecond line.")
            precondition(decoded.user?.username == "Listener")
            precondition(decoded.timestampMilliseconds == 4960)
            precondition(decoded.createdAt != nil)
        }
        for timestamp in ["null", "-1", "\"\"", "\"NaN\"", "1e100"] {
            let decoded = try decoder.decode(SoundCloudComment.self, from: Data(comment(timestamp: timestamp).utf8))
            precondition(decoded.timestampMilliseconds == nil)
        }
        for date in ["2026-09-10T12:34:56Z", "2026-09-10T12:34:56.123Z"] {
            let decoded = try decoder.decode(SoundCloudComment.self, from: Data(comment(timestamp: "0", date: date).utf8))
            precondition(decoded.createdAt != nil)
            precondition(decoded.timestampMilliseconds == 0)
        }
        // api-v2 comments carry numeric IDs; URNs still decode.
        // Deleted or partial users must not hide their comments.
        for user in ["null", "{}"] {
            let decoded = try decoder.decode(SoundCloudComment.self, from: Data("""
                {"urn":"soundcloud:comments:2","body":"Still visible","user":\(user)}
                """.utf8))
            precondition(decoded.user == nil && decoded.createdAt == nil && decoded.timestampMilliseconds == nil)
        }

        let draft = "Great \"track\"! 🎶\nMore & more"
        for timestamp: Int? in [nil, 0, 83_456] {
            CommentsURLProtocol.respond { request in
                precondition(request.httpMethod == "POST")
                precondition(request.url?.path == "/tracks/1/comments")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        precondition(count >= 0)
                        if count == 0 { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                }
                precondition(request.value(forHTTPHeaderField: "Content-Type")
                    == "application/x-www-form-urlencoded; charset=UTF-8")
                var form = URLComponents()
                form.percentEncodedQuery = String(decoding: body, as: UTF8.self)
                    .replacingOccurrences(of: "+", with: "%20")
                let fields = Dictionary(uniqueKeysWithValues: form.queryItems!.map { ($0.name, $0.value) })
                precondition(fields["body"] == draft)
                precondition(fields["timestamp"] == timestamp.map(String.init))
                return (201, comment(timestamp: timestamp.map(String.init) ?? "null"))
            }
            let posted = try await client.addTrackComment(
                urn: "soundcloud:tracks:1", body: draft,
                timestampMilliseconds: timestamp, accessToken: "test-token"
            )
            precondition(posted.urn == "soundcloud:comments:1234")
            precondition(posted.user?.username == "Listener")
            precondition(posted.timestampMilliseconds == timestamp)
        }
        CommentsURLProtocol.respond { _ in fatalError("Empty comment was sent") }
        do {
            _ = try await client.addTrackComment(urn: "soundcloud:tracks:1", body: " \n ", accessToken: "test-token")
            fatalError("Empty comment was accepted")
        } catch SoundCloudError.api {}
        for status in [401, 403, 422, 429] {
            CommentsURLProtocol.respond { _ in (status, "{}") }
            do {
                _ = try await client.addTrackComment(urn: "soundcloud:tracks:1", body: draft, accessToken: "test-token")
                fatalError("Failed post was accepted")
            } catch SoundCloudError.unauthorized { precondition(status == 401)
            } catch SoundCloudError.rateLimited { precondition(status == 429)
            } catch SoundCloudError.api { precondition(status == 403 || status == 422) }
        }
        CommentsURLProtocol.respond { _ in (201, "{}") }
        do {
            _ = try await client.addTrackComment(urn: "soundcloud:tracks:1", body: draft, accessToken: "test-token")
            fatalError("Malformed posted comment was accepted")
        } catch is DecodingError {}

        let nextURL = URL(string: "https://api-v2.soundcloud.com/tracks/1/comments?cursor=next")!
        CommentsURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            precondition(request.url?.path == "/tracks/1/comments")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "limit", value: "50")))
            precondition(query.contains(URLQueryItem(name: "linked_partitioning", value: "1")))
            precondition(query.contains(URLQueryItem(name: "threaded", value: "1")))
            precondition(query.contains(URLQueryItem(name: "secret_token", value: "s-private")))
            return (200, """
                {"collection":[\(comment(timestamp: "4960"))],"next_href":"\(nextURL.absoluteString)"}
                """)
        }
        let page = try await client.trackComments(urn: "soundcloud:tracks:1", secretToken: "s-private", accessToken: "test-token")
        precondition(page.comments.count == 1 && page.nextURL == nextURL)
        CommentsURLProtocol.respond { request in
            precondition(request.url == nextURL)
            return (200, "{\"collection\":[],\"next_href\":null}")
        }
        let lastPage = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token", pageURL: nextURL)
        precondition(lastPage.comments.isEmpty && lastPage.nextURL == nil)

        func threaded(_ entries: [(Int, String)]) throws -> [SoundCloudComment] {
            try entries.map { id, timestamp in
                try decoder.decode(SoundCloudComment.self, from: Data("""
                    {"id":\(id),"body":"","timestamp":\(timestamp)}
                    """.utf8))
            }
        }
        var threader = SoundCloudCommentThreader()
        let first = threader.parentURNs(in: try threaded([
            (1, "500"), (2, "500"), (3, "500"), (4, "900"), (5, "null"), (6, "null"), (7, "0"), (8, "0"),
        ]))
        precondition(first == [
            "soundcloud:comments:2": "soundcloud:comments:1",
            "soundcloud:comments:3": "soundcloud:comments:1",
            "soundcloud:comments:8": "soundcloud:comments:7",
        ])
        // A thread split across pages continues from the previous page's last root.
        let second = threader.parentURNs(in: try threaded([(9, "0"), (10, "500"), (11, "500")]))
        precondition(second == [
            "soundcloud:comments:9": "soundcloud:comments:7",
            "soundcloud:comments:11": "soundcloud:comments:10",
        ])

        for status in [401, 404, 429] {
            CommentsURLProtocol.respond { _ in (status, "{}") }
            do {
                _ = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token")
                fatalError("HTTP \(status) was accepted")
            } catch SoundCloudError.unauthorized { precondition(status == 401)
            } catch SoundCloudError.rateLimited { precondition(status == 429)
            } catch SoundCloudError.api { precondition(status == 404) }
        }
        for body in ["{}", "{\"collection\":[{}]}"] {
            CommentsURLProtocol.respond { _ in (200, body) }
            do {
                _ = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token")
                fatalError("Malformed comments were accepted")
            } catch is DecodingError {}
        }
        CommentsURLProtocol.respond { _ in fatalError("Untrusted URL was requested") }
        do {
            _ = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token",
                pageURL: URL(string: "https://example.com/comments")!)
            fatalError("Untrusted page URL was accepted")
        } catch SoundCloudError.unexpectedURL {}
        for href in ["https://example.com/comments", "http://api-v2.soundcloud.com/comments"] {
            CommentsURLProtocol.respond { _ in (200, "{\"collection\":[],\"next_href\":\"\(href)\"}") }
            do {
                _ = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token")
                fatalError("Untrusted next URL was accepted")
            } catch SoundCloudError.unexpectedURL {}
        }
        CommentsURLProtocol.respond { request in
            (200, "{\"collection\":[],\"next_href\":\"\(request.url!.absoluteString)\"}")
        }
        do {
            _ = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token")
            fatalError("Repeated page URL was accepted")
        } catch SoundCloudError.invalidData {}

        // Comment likes are GraphQL reactions on graph.soundcloud.com.
        func graphQLBody(_ request: URLRequest) -> [String: Any] {
            precondition(request.httpMethod == "POST")
            precondition(request.url?.host == "graph.soundcloud.com" && request.url?.path == "/graphql")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            precondition(request.value(forHTTPHeaderField: "Apollographql-Client-Name") == "v2")
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            return try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        }
        CommentsURLProtocol.respond { request in
            let body = graphQLBody(request)
            precondition(body["operationName"] as? String == "UserInteractions")
            let variables = body["variables"] as! [String: Any]
            precondition(variables["parentUrn"] as? String == "soundcloud:tracks:1")
            precondition(variables["interactionTypeUrn"] as? String == "sc:interactiontype:reaction")
            precondition(variables["targetUrns"] as? [String]
                == ["soundcloud:comments:1", "soundcloud:comments:2", "soundcloud:comments:3"])
            return (200, """
                {"data":{"userInteractions":[
                  {"targetUrn":"soundcloud:comments:1","userInteraction":"sc:interactiontypevalue:like",
                   "interactionCounts":[{"count":3,"interactionTypeValueUrn":"sc:interactiontypevalue:like"}]},
                  {"targetUrn":"soundcloud:comments:2","userInteraction":null,"interactionCounts":[]}
                ]}}
                """)
        }
        let likes = try await client.commentLikes(
            trackURN: "soundcloud:tracks:1",
            commentURNs: ["soundcloud:comments:1", "soundcloud:comments:2", "soundcloud:comments:3"],
            accessToken: "test-token"
        )
        precondition(likes["soundcloud:comments:1"] == SoundCloudCommentLikes(count: 3, isLiked: true))
        precondition(likes["soundcloud:comments:2"] == SoundCloudCommentLikes(count: 0, isLiked: false))
        precondition(likes["soundcloud:comments:3"] == nil)

        CommentsURLProtocol.respond { _ in fatalError("Empty like query was sent") }
        let noLikes = try await client.commentLikes(
            trackURN: "soundcloud:tracks:1", commentURNs: [], accessToken: "test-token"
        )
        precondition(noLikes.isEmpty)

        // GraphQL reports failures in a 200 reply.
        CommentsURLProtocol.respond { _ in
            (200, #"{"errors":[{"message":"FORBIDDEN"}],"data":{"userInteractions":null}}"#)
        }
        do {
            _ = try await client.commentLikes(
                trackURN: "soundcloud:tracks:1", commentURNs: ["soundcloud:comments:1"], accessToken: "test-token"
            )
            fatalError("GraphQL error was accepted")
        } catch let SoundCloudError.api(message) { precondition(message == "FORBIDDEN") }

        for isLiked in [true, false] {
            CommentsURLProtocol.respond { request in
                let body = graphQLBody(request)
                let operation = isLiked ? "UpsertInteraction" : "RemoveInteraction"
                precondition(body["operationName"] as? String == operation)
                precondition((body["query"] as! String).contains("mutation \(operation)("))
                let input = (body["variables"] as! [String: Any])["input"] as! [String: String]
                precondition(input == [
                    "parentUrn": "soundcloud:tracks:1",
                    "interactionTypeUrn": "sc:interactiontype:reaction",
                    "interactionTypeValueUrn": "sc:interactiontypevalue:like",
                    "targetUrn": "soundcloud:comments:2",
                ])
                return (200, isLiked
                    ? #"{"data":{"upsertInteraction":{"targetUrn":"soundcloud:comments:2"}}}"#
                    : #"{"data":{"removeInteraction":true}}"#)
            }
            try await client.setCommentLiked(
                trackURN: "soundcloud:tracks:1", commentURN: "soundcloud:comments:2",
                isLiked: isLiked, accessToken: "test-token"
            )
        }
        CommentsURLProtocol.respond { request in
            precondition(request.httpMethod == "DELETE")
            precondition(request.url?.path == "/comments/1234")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            return (200, "")
        }
        try await client.deleteTrackComment(urn: "soundcloud:comments:1234", accessToken: "test-token")
        for status in [403, 404] {
            CommentsURLProtocol.respond { _ in (status, "{}") }
            do {
                try await client.deleteTrackComment(urn: "soundcloud:comments:1234", accessToken: "test-token")
                fatalError("Failed delete was accepted")
            } catch SoundCloudError.api {}
        }
        print("Comment decoding and API checks passed")
    }
}

private final class CommentsURLProtocol: URLProtocol {
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
        let (request, me) = APITestSupport.prepare(self.request)
        let (status, body) = me ?? handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
