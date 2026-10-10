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
            let expected = timed.filter { abs(seconds($0) - time) <= 3 }
                .min { abs(seconds($0) - time) < abs(seconds($1) - time) }?.id
            precondition(index.playbackCommentID(at: time) == expected, "Playback mismatch at \(time)")
        }
        for duration in [0.0, 0.001, 30, 120] {
            let visible = duration > 0 ? timed.filter { seconds($0) <= duration }.sorted {
                seconds($0) == seconds($1) ? $0.id < $1.id : seconds($0) < seconds($1)
            } : []
            precondition(index.visibleComments(duration: duration).map(\.id) == visible.map(\.id))
            for width in [1.0, 20, 28, 100, 800] {
                let placements = index.markerPlacements(width: width, duration: duration)
                precondition(placements.map { $0.comment.id } == visible.map(\.id))
                for (i, marker) in placements.enumerated() {
                    precondition(marker.x >= 0 && marker.x <= width)
                    if i > 0 { precondition(marker.x > placements[i - 1].x) }
                    precondition(index.hoverCommentID(at: marker.x, placements: placements) == marker.comment.id,
                                 "Every marker must have its own hover target")
                }
                for x in stride(from: -20.0, through: width + 20, by: 2.5) {
                    let nearest = placements.min { abs($0.x - x) < abs($1.x - x) }
                    let expected = nearest.flatMap { abs($0.x - x) <= 14 ? $0.comment.id : nil }
                    precondition(index.hoverCommentID(at: x, placements: placements) == expected)
                }
            }
        }
        let sparse = WaveformCommentIndex(try [comment(9, 10_000), comment(1, 6_000), comment(0, 10_000)])
        precondition(sparse.playbackCommentID(at: 8) == "9") // First-loaded tie, not sorted ID.
        precondition(sparse.playbackCommentID(at: 3) == "1")
        precondition(sparse.playbackCommentID(at: 2.999) == nil)
        precondition(sparse.playbackCommentID(at: 13) == "9")
        precondition(sparse.playbackCommentID(at: 13.001) == nil)
        precondition(sparse.playbackCommentID(at: .nan) == nil)
        let duplicates = WaveformCommentIndex(try [comment(1, 0), comment(2, 0),
            comment(3, 50_000), comment(4, 50_000), comment(5, 100_000), comment(6, 100_000)])
        let positions = duplicates.markerPlacements(width: 600, duration: 100)
        precondition(positions.map(\.x) == [16, 24, 300, 308, 576, 584])
        precondition(positions.map { $0.comment.timestampMilliseconds! } == [0, 0, 50_000, 50_000, 100_000, 100_000])
        print("Waveform comment index tests passed (5,000 comments)")
    }
}
