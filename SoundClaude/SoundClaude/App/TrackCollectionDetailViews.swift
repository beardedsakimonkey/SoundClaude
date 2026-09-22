import SwiftUI

struct TrackCollectionBackdrop: View {
    let artworkURL: URL?
    let loader: ArtworkLoader

    var body: some View {
        let backdrop = TrackArtworkBackdropView(
            artworkURL: artworkURL,
            loader: loader,
            fadesToBottom: false,
            animatesChanges: true
        )
        .frame(height: 600)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.25),
                    .init(color: .black.opacity(0.5), location: 0.65),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        if #available(macOS 26.0, *) {
            backdrop.backgroundExtensionEffect()
        } else {
            backdrop
        }
    }
}

struct TrackCollectionTracks: View {
    let tracks: [SoundCloudTrack]
    let trackLayout: TrackLayout
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void
    var fadesInTracks = false
    var onRemoveFromPlaylist: ((SoundCloudTrack) -> Void)? = nil
    var isUpdatingPlaylist = false

    var body: some View {
        if trackLayout == .grid {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 20, alignment: .top)],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(tracks) { track in
                    TrackGridTile(
                        track: track,
                        playback: model.playback,
                        analyzer: model.analyzer,
                        artworkLoader: model.artworkLoader,
                        likes: model.likes,
                        onAddToQueue: model.addToQueue,
                        onRemoveFromPlaylist: onRemoveFromPlaylist,
                        isUpdatingPlaylist: isUpdatingPlaylist,
                        onSelectTrack: onSelectTrack,
                        onSelectArtist: onSelectArtist,
                        onPlayTrack: onPlayTrack
                    )
                    .modifier(FadeInOnAppear(isEnabled: fadesInTracks))
                }
            }
            .padding(.bottom, 16)
        } else {
            ForEach(tracks) { track in
                TrackListRow(
                    track: track,
                    playback: model.playback,
                    analyzer: model.analyzer,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onAddToQueue: model.addToQueue,
                    onRemoveFromPlaylist: onRemoveFromPlaylist,
                    isUpdatingPlaylist: isUpdatingPlaylist,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: onPlayTrack
                )
                .modifier(FadeInOnAppear(isEnabled: fadesInTracks))
            }
        }
    }
}
