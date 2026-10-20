import SwiftUI

extension EnvironmentValues {
    @Entry var openTrackStation: (SoundCloudTrack) -> Void = { _ in }
}

struct TrackStationMenuItem: View {
    let track: SoundCloudTrack
    @Environment(\.openTrackStation) private var openTrackStation

    var body: some View {
        Button("Start station", systemImage: "dot.radiowaves.left.and.right") {
            openTrackStation(track)
        }
        .keyboardShortcut(nil)
    }
}
