import SwiftUI

struct NowPlayingTrackRow: View {
    enum Layout { case inline, stacked }

    let track: SoundCloudTrack?
    var layout: Layout = .inline
    var artworkLoader: ArtworkLoader? = nil
    /// Dims the title while the track is only a preview of what would play.
    var isTitleDimmed = false
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var isHoveringTrackTitle = false

    var body: some View {
        // The placeholder alone sizes the row. Track transitions stay in an
        // overlay and cannot remeasure the detail header.
        Text(" ")
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, minHeight: layout == .stacked ? 64 : 22, alignment: .leading)
            .overlay(alignment: .leading) {
                if let track {
                    let arrangement = layout == .stacked
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                    arrangement {
                        Button {
                            onSelectTrack(track)
                        } label: {
                            Text(track.title)
                                .lineLimit(1)
                                .minimumScaleFactor(layout == .stacked ? 0.6 : 1)
                                .truncationMode(.tail)
                                .underline(isHoveringTrackTitle)
                                .font(layout == .stacked ? .system(size: 28, weight: .semibold) : .title2)
                                .foregroundStyle(isTitleDimmed ? HierarchicalShapeStyle.secondary : .primary)
                                .opacity(0.9)
                                .animation(.easeInOut(duration: 0.35), value: isTitleDimmed)
                        }
                        .buttonStyle(.plain)
                        .onContentHover { isHoveringTrackTitle = $0 }
                        .contentHelp("View track: \(track.title)")
                        .accessibilityLabel("View track: \(track.title)")
                        if layout == .inline {
                            Text("by")
                                .foregroundStyle(.secondary)
                                .opacity(0.9)
                                .fixedSize()
                        }
                        ArtistLink(
                            artist: track.artist,
                            artworkLoader: artworkLoader,
                            showsAvatarBorder: layout == .stacked,
                            onSelect: onSelectArtist
                        )
                        .font(layout == .stacked ? .title3 : .title2)
                        .foregroundStyle(layout == .stacked ? .secondary : .primary)
                        .opacity(layout == .stacked ? 1 : 0.9)
                    }
                    .foregroundStyle(.primary)
                    .geometryGroup()
                    .id(track.urn)
                    .transition(.identity)
                    // Keep the fade outside the track identity so it only runs on appearance.
                    .modifier(FadeInOnAppear())
                }
            }
        .font(.title2)
        .onChange(of: track?.urn) { _, _ in
            isHoveringTrackTitle = false
        }
    }
}
