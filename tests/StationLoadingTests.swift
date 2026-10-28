import AppKit
import Observation
import SwiftUI

enum SoundCloudError: Error { case invalidData }

// Exercise the real station view while holding its awaiting load task suspended.
// Child views and services are deterministic; no account or network is needed.
@MainActor @Observable final class AppModel {
    var loadingStations: [String: SoundCloudStation] = [:]
    let cache = MemoryCache<NSString, SoundCloudStation>(countLimit: 10)
    var completion: CheckedContinuation<SoundCloudStation, Never>?
    let playback = 0
    let queue = TrackQueue(source: .single, tracks: [])
    var errorMessage: String?
    var likeErrorMessage: String?
    func cachedStation(urn: String) -> SoundCloudStation? { cache.value(forKey: urn as NSString) }
    func station(urn: String) async throws -> SoundCloudStation {
        await withCheckedContinuation { completion = $0 }
    }
    enum StationSource { case track(SoundCloudTrack), artist(SoundCloudUser) }
    func stationSource(urn: String) async throws -> StationSource { fatalError("Unused") }
}
@MainActor @Observable final class LikesController {
    var likedStationURNs: Set<String> = []
    var updatingStationURNs: Set<String> = []
    var isLoadingStationLikes = false
    func loadStationLikes() async throws {}
    func toggleStationLike(urn: String, title: String) async throws {}
}
struct TrackCollection {
    enum Kind { case station }
    let kind: Kind
    let urn: String
    let title: String
    let tracks: [SoundCloudTrack]
    let seedTrack: SoundCloudTrack?
}
@MainActor private enum Measurements { static var trackCounts: [Int] = [] }
struct TrackCollectionHeader<Title: View, Footer: View>: View {
    let collection: TrackCollection
    let model: AppModel
    let likes: LikesController
    let showsControls: Bool
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    @ViewBuilder let title: () -> Title
    @ViewBuilder let controlsFooter: () -> Footer
    var body: some View {
        let _ = Measurements.trackCounts.append(collection.tracks.count)
        Button("Start") {}.disabled(collection.tracks.isEmpty)
    }
}
struct ScrollbarReservedScrollView<Content: View>: View {
    @ViewBuilder let content: (Int) -> Content
    var body: some View { content(0) }
}
struct TrackCollectionSection<Content: View>: View {
    let count: Int
    let errorMessage: String?
    @ViewBuilder let content: (Int) -> Content
    var body: some View { content(0) }
}
struct TrackCollectionTrackList: View, Equatable {
    let collection: TrackCollection
    let trackLayout: Int
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { false }
    var body: some View { EmptyView() }
}
struct TrackCollectionLoadStatus: View {
    let errorMessage: String?
    let isLoading: Bool
    let isEmpty: Bool
    let loadingLabel: String
    let emptyMessage: String
    let onRetry: () -> Void
    var body: some View { EmptyView() }
}
struct TrackCollectionBackdrop: View {
    let collection: TrackCollection
    let model: AppModel
    var body: some View { Color.clear }
}
struct TrackCollectionTitleRow<Title: View, Actions: View>: View {
    @ViewBuilder let title: () -> Title
    @ViewBuilder let actions: () -> Actions
    var body: some View { title(); actions() }
}
struct StationPlayingIcon: View {
    let playback: Int
    let isCurrent: Bool
    var body: some View { EmptyView() }
}
struct TrackCollectionLikeButton: View {
    let isLiked: Bool
    let isUpdating: Bool
    let subject: String
    let action: () -> Void
    var body: some View { EmptyView() }
}
struct OpenInSoundCloudButton: View {
    let url: URL?
    var body: some View { EmptyView() }
}
extension View {
    func contentHelp(_ text: String) -> some View { self }
    func onContentHover(_ action: @escaping (Bool) -> Void) -> some View { self }
}

@main struct StationLoadingTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let model = AppModel()
        let urn = "station"
        let artist = SoundCloudUser(urn: "artist", username: "Artist", avatarURL: nil,
                                    permalinkURL: URL(string: "https://soundcloud.com/artist")!)
        let track = SoundCloudTrack(
            urn: "track", title: "Track", artist: artist, artworkURL: nil, waveformURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/artist/track")!,
            durationMilliseconds: 1_000, access: .playable, secretToken: nil
        )
        let result = SoundCloudStation(title: "Station", description: nil, permalinkURL: nil,
                                      lastUpdated: nil, trackCount: 1, tracks: [track])
        let host = NSHostingView(rootView: StationDetailView(
            urn: urn, seedTrack: track, seedArtistName: nil, model: model,
            likes: LikesController(), onSelectTrack: { _ in }, onSelectArtist: { _ in }
        ))
        host.frame.size = CGSize(width: 800, height: 600)
        func render() async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
        }
        await render()
        precondition(model.completion != nil)
        precondition(Measurements.trackCounts.last == 0)
        model.loadingStations[urn] = result
        await render()
        precondition(Measurements.trackCounts.last == 1)
        Measurements.trackCounts = []

        // Match production: cache the result and clear progress BEFORE resuming the view.
        model.cache.insert(result, forKey: urn as NSString)
        model.loadingStations[urn] = nil
        await render()
        precondition(!Measurements.trackCounts.isEmpty)
        precondition(Measurements.trackCounts.allSatisfy { $0 == 1 },
                     "Start must stay enabled during the completion handoff")
        model.completion?.resume(returning: result)
        model.completion = nil
        await render()
        precondition(Measurements.trackCounts.allSatisfy { $0 == 1 })
        print("Station completion handoff keeps Start enabled")
    }
}
