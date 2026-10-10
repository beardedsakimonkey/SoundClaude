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
                func position(_ comment: SoundCloudComment) -> Double {
                    let inset = min(14, width / 2)
                    return min(max(seconds(comment) / duration * width, inset), width - inset)
                }
                for x in stride(from: -20.0, through: width + 20, by: 2.5) {
                    let nearest = visible.min { abs(position($0) - x) < abs(position($1) - x) }
                    let expected = nearest.flatMap { nearest -> String? in
                        let center = position(nearest)
                        guard abs(center - x) <= 14 else { return nil }
                        let group = visible.filter { position($0) == center }
                        guard group.count > 1 else { return nearest.id }
                        let previous = visible.last { position($0) < center }.map(position)
                        let next = visible.first { position($0) > center }.map(position)
                        let left = max(0, center - 14, previous.map { ($0 + center) / 2 } ?? 0)
                        let right = min(width, center + 14, next.map { ($0 + center) / 2 } ?? width)
                        let fraction = min(max((x - left) / (right - left), 0), 1)
                        return group[min(Int(fraction * Double(group.count)), group.count - 1)].id
                    }
                    precondition(index.hoverCommentID(at: x, width: width, duration: duration) == expected,
                                 "Hover mismatch at \(x), width \(width), duration \(duration)")
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
        // Sweep across one stationary marker to reach each duplicate separately.
        let shared = WaveformCommentIndex(try [comment(1, 50_000), comment(2, 50_000), comment(3, 50_000)])
        for (x, id) in [(290.0, "1"), (300.0, "2"), (310.0, "3")] {
            precondition(shared.hoverCommentID(at: x, width: 600, duration: 100) == id)
        }
        precondition(shared.hoverCommentID(at: 285, width: 600, duration: 100) == nil)
        // Neighboring markers bound the shared hit area without losing their own targets.
        let crowded = shared.appending(try [comment(0, 49_000), comment(4, 51_000)])
        for (x, id) in [(294.0, "0"), (298.0, "1"), (300.0, "2"), (302.0, "3"), (306.0, "4")] {
            precondition(crowded.hoverCommentID(at: x, width: 600, duration: 100) == id)
        }
        let edges = WaveformCommentIndex(try [comment(1, 0), comment(2, 0),
                                              comment(3, 100_000), comment(4, 100_000)])
        for (x, id) in [(5.0, "1"), (23.0, "2"), (577.0, "3"), (595.0, "4")] {
            precondition(edges.hoverCommentID(at: x, width: 600, duration: 100) == id)
        }
        print("Waveform comment index tests passed (5,000 comments)")
    }
}
