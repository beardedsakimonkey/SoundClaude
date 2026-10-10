import Foundation

// Immutable snapshots make view equality cheap. Rebuild only when pages arrive;
// duration, playback and pointer changes query the existing sorted arrays.
struct WaveformCommentPlacement {
    let comment: SoundCloudComment
    var x: CGFloat
}

final class WaveformCommentIndex {
    let comments: [SoundCloudComment]
    private let sourceComments: [SoundCloudComment]
    private let playbackEntries: [(seconds: Double, id: String, order: Int)]

    init(_ comments: [SoundCloudComment]) {
        sourceComments = comments.filter { $0.timestampMilliseconds != nil }
        self.comments = sourceComments.sorted {
            if $0.timestampMilliseconds == $1.timestampMilliseconds { return $0.id < $1.id }
            return $0.timestampMilliseconds! < $1.timestampMilliseconds!
        }
        var seen = Set<Int>()
        playbackEntries = sourceComments.enumerated().compactMap { order, comment in
            let timestamp = comment.timestampMilliseconds!
            guard seen.insert(timestamp).inserted else { return nil }
            return (Double(timestamp) / 1_000, comment.id, order)
        }.sorted { $0.seconds < $1.seconds }
    }

    func appending(_ comments: [SoundCloudComment]) -> WaveformCommentIndex {
        WaveformCommentIndex(sourceComments + comments)
    }

    func visibleComments(duration: Double) -> ArraySlice<SoundCloudComment> {
        guard duration > 0 else { return comments.prefix(0) }
        let end = lowerBound(count: comments.count) { seconds(at: $0) > duration }
        return comments.prefix(end)
    }

    func playbackCommentID(at time: Double) -> String? {
        guard time.isFinite, !playbackEntries.isEmpty else { return nil }
        let upper = lowerBound(count: playbackEntries.count) { playbackEntries[$0].seconds >= time }
        let candidates = [upper - 1, upper].filter { playbackEntries.indices.contains($0) }
        let nearest = candidates.min {
            let a = abs(playbackEntries[$0].seconds - time)
            let b = abs(playbackEntries[$1].seconds - time)
            // Preserve the original first-loaded tie rule, including duplicates.
            return a == b ? playbackEntries[$0].order < playbackEntries[$1].order : a < b
        }!
        let entry = playbackEntries[nearest]
        // Expand the nearest avatar within three seconds before or after its timestamp.
        return abs(entry.seconds - time) <= 3 ? entry.id : nil
    }

    // Give overlapping markers separate hover targets while keeping sparse
    // markers at their timestamps. Shift the row back inside the right edge.
    func markerPlacements(width: CGFloat, duration: Double) -> [WaveformCommentPlacement] {
        guard width.isFinite, width > 0, duration.isFinite, duration > 0 else { return [] }
        let visible = visibleComments(duration: duration)
        guard !visible.isEmpty else { return [] }
        let inset = min(16, width / 4)
        let spacing = min(8, (width - 2 * inset) / CGFloat(max(1, visible.count - 1)))
        var placements: [WaveformCommentPlacement] = []
        for comment in visible {
            let seconds = Double(comment.timestampMilliseconds!) / 1_000
            let desired = min(max(CGFloat(seconds / duration) * width, inset), width - inset)
            let x = max(desired, placements.last.map { $0.x + spacing } ?? inset)
            placements.append(WaveformCommentPlacement(comment: comment, x: x))
        }
        var limit = width - inset
        for i in placements.indices.reversed() {
            placements[i].x = min(placements[i].x, limit)
            limit = placements[i].x - spacing
        }
        return placements
    }

    func hoverCommentID(at x: CGFloat, width: CGFloat, duration: Double) -> String? {
        hoverCommentID(at: x, placements: markerPlacements(width: width, duration: duration))
    }

    func hoverCommentID(at x: CGFloat, placements: [WaveformCommentPlacement]) -> String? {
        guard x.isFinite, !placements.isEmpty else { return nil }
        let upper = lowerBound(count: placements.count) { placements[$0].x >= x }
        var nearest = min(upper, placements.count - 1)
        if upper > 0, abs(placements[upper - 1].x - x) <= abs(placements[nearest].x - x) {
            nearest = upper - 1
        }
        return abs(placements[nearest].x - x) <= 14 ? placements[nearest].comment.id : nil
    }

    private func seconds(at index: Int) -> Double {
        Double(comments[index].timestampMilliseconds!) / 1_000
    }

    private func lowerBound(count: Int, predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
