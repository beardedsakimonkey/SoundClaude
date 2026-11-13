import SwiftUI

// SearchView draws result artwork; these suites only need its footprint.
struct ArtworkLoader {}

struct TrackArtworkView: View {
    let artworkURL: URL?
    let loader: ArtworkLoader
    let size: CGFloat
    var shape = RoundedRectangle(cornerRadius: 3)

    var body: some View {
        shape.fill(.quaternary).frame(width: size, height: size)
    }
}
