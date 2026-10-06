import AppKit
import SwiftUI

struct SoundCloudUser { let username: String }
struct SoundCloudTrack { let urn: String; let title: String; let artist: SoundCloudUser }
struct ArtworkLoader {}
struct ArtistLink: View {
    let artist: SoundCloudUser
    var artworkLoader: ArtworkLoader? = nil
    var showsAvatarBorder = false
    let onSelect: (SoundCloudUser) -> Void
    var body: some View { Button(artist.username) { onSelect(artist) }.lineLimit(1) }
}
extension View {
    func onContentHover(_ action: @escaping (Bool) -> Void) -> some View { onHover(perform: action) }
    func contentHelp(_ text: String) -> some View { help(text) }
}

@main
struct NowPlayingLayoutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let artist = SoundCloudUser(username: "Artist with a long name")
        let tracks: [SoundCloudTrack?] = [
            nil,
            SoundCloudTrack(urn: "short", title: "Short", artist: artist),
            SoundCloudTrack(urn: "long", title: String(repeating: "Long track title ", count: 20), artist: artist)
        ]
        for layout: NowPlayingTrackRow.Layout in [.inline, .stacked] {
            var baseline: CGSize?
            for width: CGFloat in [240, 600] {
                for track in tracks {
                    let row = NowPlayingTrackRow(
                        track: track,
                        layout: layout,
                        artworkLoader: layout == .stacked ? ArtworkLoader() : nil,
                        onSelectTrack: { _ in }, onSelectArtist: { _ in }
                    )
                    let host = NSHostingView(rootView: row)
                    host.frame.size = CGSize(width: width, height: 40)
                    host.layoutSubtreeIfNeeded()
                    let ideal = host.fittingSize
                    if let baseline {
                        precondition(ideal == baseline,
                                     "Changing the title must not change header sizing: \(baseline) -> \(ideal)")
                    } else {
                        baseline = ideal
                    }
                }
            }
            precondition(baseline!.height >= (layout == .stacked ? 64 : 22), "Reserve row height even without a track")
        }
        print("Now Playing row keeps the same layout for empty, short, and long titles")
    }
}
