import AppKit
import Observation
import SwiftUI

@Observable private final class Playback {
    var track = "first"
}

private enum Updates {
    static var page = 0
    static var header = 0
    static var backdrop = 0
    static var displayedTrack = ""
}

private struct Page: View {
    let playback: Playback

    var body: some View {
        let _ = { Updates.page += 1 }()
        VStack {
            TrackCollectionPlaybackContent { header }
            Text("Tracks")
        }
        .background {
            TrackCollectionPlaybackContent {
                let _ = { Updates.backdrop += 1 }()
                Text(playback.track)
            }
        }
    }

    private var header: some View {
        Updates.header += 1
        Updates.displayedTrack = playback.track
        return Text(playback.track)
    }
}

@main struct TrackCollectionPlaybackContentTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let playback = Playback()
            let host = NSHostingView(rootView: Page(playback: playback))
            host.frame.size = CGSize(width: 400, height: 300)
            @MainActor func layout() async {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
            }
            await layout()
            let pageUpdates = Updates.page
            for track in ["next", "first", "other collection"] {
                let headerUpdates = Updates.header
                let backdropUpdates = Updates.backdrop
                playback.track = track
                await layout()
                precondition(Updates.page == pageUpdates, "Track change rebuilt the page")
                precondition(Updates.header > headerUpdates, "Header did not update")
                precondition(Updates.backdrop > backdropUpdates, "Backdrop did not update")
                precondition(Updates.displayedTrack == track)
            }
            print("Collection playback observation tests passed")
            exit(0)
        }
        app.run()
    }
}
