import SwiftUI

// Evaluate playback-dependent content in its own body. A computed view property
// alone still registers its observable reads with the enclosing detail page.
struct TrackCollectionPlaybackContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}
