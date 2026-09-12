import SwiftUI

struct OpenInSoundCloudButton: View {
    @Environment(\.openURL) private var openURL

    let url: URL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            Label("Open in SoundCloud", systemImage: "arrow.up.right.square")
                .labelStyle(.iconOnly)
                .frame(width: 20, height: 20)
        }
    }
}
