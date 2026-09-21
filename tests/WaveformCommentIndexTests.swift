import Foundation

@main
struct WaveformCommentIndexTests {
    static func main() throws {
        let decoder = JSONDecoder()
        func comment(_ id: Int, _ timestamp: Int?) throws -> SoundCloudComment {
            try decoder.decode(SoundCloudComment.self, from: Data("""
                {"urn":"\(id)","body":"comment","timestamp":\(timestamp.map(String.init) ?? "null")}
                """.utf8))
        }
        let empty = WaveformCommentIndex([])
        precondition(empty.playbackCommentID(at: 0) == nil)
        precondition(empty.hoverCommentID(at: 0, width: 100, duration: 10) == nil)

        // Shuffled timestamps, duplicate timestamps, and comments outside duration.
        // Compare the indexed queries with a full scan.
        let source = try (0..<5_000).map { try comment($0, ($0 * 7919) % 120_000) }
            + [comment(5_000, 0), comment(5_001, 0), comment(5_002, nil)]
        let timed = source.filter { $0.timestampMilliseconds != nil }
        let firstPage = WaveformCommentIndex(Array(source.prefix(50)))
        let index = firstPage.appending(Array(source.dropFirst(50)))
        func seconds(_ comment: SoundCloudComment) -> Double {
            Double(comment.timestampMilliseconds ?? 0) / 1_000
        }
        for time in stride(from: -3.0, through: 125.0, by: 0.125) {
            let expected = timed.filter { abs(seconds($0) - time) <= 5 }
                .min { abs(seconds($0) - time) < abs(seconds($1) - time) }?.id
            precondition(index.playbackCommentID(at: time) == expected, "Playback mismatch at \(time)")
        }
        for duration in [0.0, 0.001, 30, 120] {
            let visible = duration > 0 ? timed.filter { seconds($0) <= duration }.sorted {
                seconds($0) == seconds($1) ? $0.id < $1.id : seconds($0) < seconds($1)
            } : []
            precondition(index.visibleComments(duration: duration).map(\.id) == visible.map(\.id))
            for width in [1.0, 20, 28, 100, 800] {
                func position(_ comment: SoundCloudComment) -> Double {
                    let inset = min(14, width / 2)
                    return min(max(seconds(comment) / duration * width, inset), width - inset)
                }
                for x in stride(from: -20.0, through: width + 20, by: 2.5) {
                    let nearest = visible.min { abs(position($0) - x) < abs(position($1) - x) }
                    let expected = nearest.flatMap { abs(position($0) - x) <= 14 ? $0.id : nil }
                    precondition(index.hoverCommentID(at: x, width: width, duration: duration) == expected,
                                 "Hover mismatch at \(x), width \(width), duration \(duration)")
                }
            }
        }
        let sparse = WaveformCommentIndex(try [comment(9, 10_000), comment(1, 6_000), comment(0, 10_000)])
        precondition(sparse.playbackCommentID(at: 8) == "9") // First-loaded tie, not sorted ID.
        precondition(sparse.playbackCommentID(at: 1) == "1")
        precondition(sparse.playbackCommentID(at: 0.999) == nil)
        precondition(sparse.playbackCommentID(at: 15) == "9")
        precondition(sparse.playbackCommentID(at: 15.001) == nil)
        precondition(sparse.playbackCommentID(at: .nan) == nil)
        print("Waveform comment index tests passed (5,000 comments)")
    }
}
