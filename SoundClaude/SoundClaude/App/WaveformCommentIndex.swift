import Foundation

// Immutable snapshots make view equality cheap. Rebuild only when pages arrive;
// duration, playback and pointer changes query the existing sorted arrays.
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

    func hoverCommentID(at x: CGFloat, width: CGFloat, duration: Double) -> String? {
        guard x.isFinite, width.isFinite, width > 0, duration > 0 else { return nil }
        let count = visibleComments(duration: duration).count
        guard count > 0 else { return nil }
        let inset = min(14, width / 2)
        func position(_ index: Int) -> CGFloat {
            min(max(CGFloat(seconds(at: index) / duration) * width, inset), width - inset)
        }
        let upper = lowerBound(count: count) { position($0) >= x }
        var nearest = min(upper, count - 1)
        if upper > 0, abs(position(upper - 1) - x) <= abs(position(nearest) - x) {
            nearest = upper - 1
        }
        let nearestPosition = position(nearest)
        guard abs(nearestPosition - x) <= 14 else { return nil }
        // Share the existing hover area between comments at the same position.
        // The avatars stay at their timestamps; only hit testing is divided.
        // Include distinct timestamps that clamp to the same waveform edge.
        let first = lowerBound(count: count) { position($0) >= nearestPosition }
        let end = lowerBound(count: count) { position($0) > nearestPosition }
        guard end - first > 1 else { return comments[first].id }
        var left = max(0, nearestPosition - 14)
        var right = min(width, nearestPosition + 14)
        if first > 0 { left = max(left, (position(first - 1) + nearestPosition) / 2) }
        if end < count { right = min(right, (nearestPosition + position(end)) / 2) }
        guard right > left else { return comments[first].id }
        let fraction = min(max((x - left) / (right - left), 0), 1)
        let offset = min(Int(fraction * CGFloat(end - first)), end - first - 1)
        return comments[first + offset].id
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
