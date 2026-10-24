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

// Owns the track layout preference so toggling it re-renders only this section.
struct TrackCollectionSection<Content: View>: View {
    let count: Int
    let errorMessage: String?
    @ViewBuilder let content: (TrackLayout) -> Content

    @AppStorage("playlistTrackLayout") private var trackLayout = TrackLayout.list

    var body: some View {
        VStack(alignment: .leading, spacing: trackLayout == .list ? 4 : 12) {
            HStack {
                CountedSectionHeader(title: "Tracks", count: count)
                Spacer()
                TrackLayoutPicker(trackLayout: $trackLayout)
            }
            .modifier(FadeInOnAppear())
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.accentColor)
            }
            content(trackLayout)
        }
    }
}

struct TrackCollectionTracks: View {
    let tracks: [SoundCloudTrack]
    let trackLayout: TrackLayout
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void
    var fadesInTracks = false
    var onRemoveFromPlaylist: ((SoundCloudTrack) -> Void)? = nil
    var isUpdatingPlaylist = false
    var removingTrackURN: String? = nil

    var body: some View {
        if trackLayout == .grid {
            TrackArtworkGrid(tracks: tracks, loader: model.artworkLoader) { track in
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
                .opacity(removingTrackURN == track.urn ? 0.4 : 1)
                .animation(
                    .easeInOut(duration: 0.2),
                    value: removingTrackURN == track.urn
                )
                .modifier(FadeInOnAppear(isEnabled: fadesInTracks))
            }
            .padding(.bottom, 16)
        } else {
            TrackArtworkList(tracks: tracks, loader: model.artworkLoader) { track in
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
                .opacity(removingTrackURN == track.urn ? 0.4 : 1)
                .animation(
                    .easeInOut(duration: 0.2),
                    value: removingTrackURN == track.urn
                )
                .modifier(FadeInOnAppear(isEnabled: fadesInTracks))
            }
        }
    }
}
