import SwiftUI

// Detail pages reserve space here; the navigation host owns the visible heading.
struct DetailTrackHeadingSlot: View {
    let track: SoundCloudTrack
    var isCollection = false
    let artworkLoader: ArtworkLoader
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    var body: some View {
        DetailTrackHeading(
            track: track, isCollection: isCollection, artworkLoader: artworkLoader,
            onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist
        )
        .hidden()
        .accessibilityHidden(true)
        .anchorPreference(key: DetailTrackHeadingPreferenceKey.self, value: .bounds) {
            DetailTrackHeadingSource(
                bounds: $0, track: track, isCollection: isCollection,
                onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist
            )
        }
    }
}

struct DetailTrackHeading: View {
    let track: SoundCloudTrack
    let isCollection: Bool
    let artworkLoader: ArtworkLoader
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    @State private var isHoveringTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(track.title)
                .font(.system(size: 28, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.primary)
                .opacity(0.9)
                .underline(isCollection && isHoveringTitle)
                .textSelection(.disabled)
                .contentShape(Rectangle())
                .onTapGesture { if isCollection { onSelectTrack(track) } }
                .onContentHover { isHoveringTitle = $0 }
                .accessibilityAction(named: "View track") { onSelectTrack(track) }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ArtistLink(
                    artist: track.artist, artworkLoader: artworkLoader,
                    showsAvatarBorder: true, onSelect: onSelectArtist
                )
                .layoutPriority(1)
                RelativeTimestampView(timestamp: track.createdAt, accessibilityPrefix: "Created")
                    .lineLimit(1)
            }
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailTrackHeadingSource {
    let bounds: Anchor<CGRect>
    let track: SoundCloudTrack
    let isCollection: Bool
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
}

struct DetailTrackHeadingPreferenceKey: PreferenceKey {
    static let defaultValue: DetailTrackHeadingSource? = nil

    static func reduce(value: inout DetailTrackHeadingSource?, nextValue: () -> DetailTrackHeadingSource?) {
        value = nextValue() ?? value
    }
}

struct DetailTrackHeadingOverlay: ViewModifier {
    let artworkLoader: ArtworkLoader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(DetailTrackHeadingPreferenceKey.self) { source in
            GeometryReader { geometry in
                if let source {
                    let bounds = geometry[source.bounds]
                    ZStack(alignment: .leading) {
                        DetailTrackHeading(
                            track: source.track, isCollection: source.isCollection,
                            artworkLoader: artworkLoader,
                            onSelectTrack: source.onSelectTrack, onSelectArtist: source.onSelectArtist
                        )
                        .id(source.track.urn)
                        .transition(source.isCollection ? .opacity : .identity)
                    }
                    .animation(
                        source.isCollection && !reduceMotion ? .easeInOut(duration: 0.3) : nil,
                        value: source.track.urn
                    )
                    .modifier(FadeInOnAppear())
                    .geometryGroup()
                    .frame(width: bounds.width, height: bounds.height)
                    .position(x: bounds.midX, y: bounds.midY)
                    // Override the page animation when navigation also changes the track.
                    .animation(nil, value: source.track.urn)
                    // Scroll and resize updates stay immediate. Only the page layout animates.
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.3),
                        value: source.isCollection
                    )
                }
            }
            .clipped()
        }
    }
}
