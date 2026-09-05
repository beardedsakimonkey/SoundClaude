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
        print("Track page decoding checks passed")
    }
}
