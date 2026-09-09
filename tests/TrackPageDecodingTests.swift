import Foundation

@main
struct TrackPageDecodingTests {
    static func main() throws {
        let track = """
            {"urn":"soundcloud:tracks:123","title":"Related track",
             "permalink_url":"https://soundcloud.com/artist/track",
             "duration":120000,"access":"playable",
             "user":{"username":"Artist","permalink_url":"https://soundcloud.com/artist"}}
            """
        let nextURL = "https://api.soundcloud.com/tracks/soundcloud:tracks:1/related?cursor=next"
        let decoder = JSONDecoder()
        let withoutCounts = try decoder.decode(RawTrack.self, from: Data(track.utf8)).normalized()!
        precondition(withoutCounts.likesCount == nil)
        precondition(withoutCounts.repostsCount == nil)
        precondition(withoutCounts.commentCount == nil)
        precondition(withoutCounts.genre == nil)
        let withGenreJSON = String(track.dropLast()) + ",\"genre\":\"Ambient\"}"
        let withGenre = try decoder.decode(RawTrack.self, from: Data(withGenreJSON.utf8)).normalized()!
        precondition(withGenre.genre == "Ambient")
        let genreCache = try JSONEncoder().encode(withGenre)
        let restoredGenre = try decoder.decode(SoundCloudTrack.self, from: genreCache)
        precondition(restoredGenre == withGenre)
        var legacyGenreJSON = try JSONSerialization.jsonObject(with: genreCache) as! [String: Any]
        legacyGenreJSON.removeValue(forKey: "genre")
        let legacyGenre = try decoder.decode(
            SoundCloudTrack.self,
            from: JSONSerialization.data(withJSONObject: legacyGenreJSON)
        )
        precondition(legacyGenre == withoutCounts)
        var withCounts = withoutCounts
        withCounts.likesCount = 1234
        withCounts.repostsCount = 56
        withCounts.commentCount = 0
        let encoded = try JSONEncoder().encode(withCounts)
        let restored = try decoder.decode(SoundCloudTrack.self, from: encoded)
        precondition(restored == withCounts)
        // Track caches and saved queues from older versions do not have these keys.
        var legacyJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["likesCount", "repostsCount", "commentCount"] {
            legacyJSON.removeValue(forKey: key)
        }
        let legacy = try decoder.decode(
            SoundCloudTrack.self,
            from: JSONSerialization.data(withJSONObject: legacyJSON)
        )
        precondition(legacy == withoutCounts)
        let fixtures: [(String, Int, String?)] = [
            ("[\(track)]", 1, nil),
            ("[]", 0, nil),
            ("{\"collection\":[\(track)],\"next_href\":\"\(nextURL)\"}", 1, nextURL),
            ("{\"collection\":[\(track)],\"next_href\":null}", 1, nil),
            ("{\"collection\":[]}", 0, nil),
        ]
        for (json, count, next) in fixtures {
            let page = try decoder.decode(RawTrackPage.self, from: Data(json.utf8))
            precondition(page.collection.count == count)
            precondition(page.collection.compactMap { $0.normalized() }.count == count)
            precondition(page.nextURL?.absoluteString == next)
        }
        for value in ["\"\"", "null", "\"https://wave.sndcdn.com/example.json\""] {
            let withWaveform = String(track.dropLast()) + ",\"waveform_url\":\(value)}"
            let page = try decoder.decode(
                RawTrackPage.self,
                from: Data("{\"collection\":[\(withWaveform)]}".utf8)
            )
            let normalized = page.collection.first?.normalized()
            precondition(normalized != nil)
            precondition(normalized?.waveformURL?.absoluteString == (
                value.contains("https:") ? "https://wave.sndcdn.com/example.json" : nil
            ))
        }
        for json in ["{}", "[123]", "{\"collection\":[123]}", "{\"collection\":{}}"] {
            do {
                _ = try decoder.decode(RawTrackPage.self, from: Data(json.utf8))
                fatalError("Malformed response was accepted: \(json)")
            } catch is DecodingError {
                // Invalid data must remain an error, not become an empty page.
            }
        }
        let artist = SoundCloudUser(
            urn: "soundcloud:users:1", username: "Artist", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/artist")!
        )
        let banner = "https://i1.sndcdn.com/visuals-example-original.jpg"
        func profileHTML(_ visuals: String, permalink: String = "https://soundcloud.com/artist") -> String {
            """
            <script>window.__sc_hydration = [{"hydratable":"user","data":{
            "permalink_url":"\(permalink)","visuals":\(visuals)}}];</script>
            """
        }
        let visuals = """
            {"enabled":true,"visuals":[{"visual_url":"\(banner)"}]}
            """
        precondition(SoundCloudProfileHeader.imageURL(
            in: profileHTML(visuals), for: artist
        )?.absoluteString == banner)
        for permalink in [
            "http://soundcloud.com/artist",
            "https://www.soundcloud.com/artist/",
            "https://soundcloud.com/artist?source=test#profile"
        ] {
            let variant = SoundCloudUser(
                urn: artist.urn, username: artist.username, avatarURL: nil,
                permalinkURL: URL(string: permalink)!
            )
            precondition(SoundCloudProfileHeader.profileURL(variant.permalinkURL) == artist.permalinkURL)
            precondition(SoundCloudProfileHeader.imageURL(
                in: profileHTML(visuals), for: variant
            )?.absoluteString == banner)
        }
        precondition(SoundCloudProfileHeader.profileURL(URL(string: "https://example.com/artist")!) == nil)
        for html in [
            "<html>No hydration data</html>",
            "<script>window.__sc_hydration = invalid;</script>",
            profileHTML("null"),
            profileHTML("{}"),
            profileHTML(visuals.replacingOccurrences(of: "true", with: "false")),
            profileHTML(visuals, permalink: "https://soundcloud.com/someone-else"),
            profileHTML(visuals.replacingOccurrences(of: banner, with: "https://example.com/image.jpg")),
            profileHTML(visuals.replacingOccurrences(of: "https://i1", with: "http://i1"))
        ] {
            precondition(SoundCloudProfileHeader.imageURL(in: html, for: artist) == nil)
        }
        print("Track page decoding checks passed")
    }
}
