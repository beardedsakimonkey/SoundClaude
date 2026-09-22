import CoreTransferable
import UniformTypeIdentifiers

/// A separate type keeps playlist drops distinct from queue reorder drags.
struct TrackPlaylistDrag: Codable, Transferable {
    let track: SoundCloudTrack

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .soundClaudeTrack)
            .visibility(.ownProcess)
    }
}

extension UTType {
    static let soundClaudeTrack = UTType(
        exportedAs: "com.tim.soundclaude.native.track",
        conformingTo: .data
    )
}
