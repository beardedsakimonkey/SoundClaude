import SwiftUI

struct WaveformCommentsView: View {
    let track: SoundCloudTrack
    let model: AppModel
    let duration: Double
    let showsComments: Bool
    let onSeek: (Double) -> Void

    @State private var index = WaveformCommentIndex([])
    @State private var playbackID: String?
    @State private var seekRequest: Double?

    var body: some View {
        WaveformCommentMarkers(
            index: index,
            model: model,
            duration: duration,
            showsComments: showsComments,
            playbackID: playbackID,
            seekRequest: $seekRequest
        )
        .equatable()
        .background {
            WaveformCommentPlaybackObserver(
                index: index, playback: model.playback, trackURN: track.urn,
                activeID: $playbackID
            )
        }
        .task { await loadComments() }
        .onChange(of: seekRequest) { _, fraction in
            guard let fraction else { return }
            onSeek(fraction)
            seekRequest = nil
        }
    }

    private func loadComments() async {
        var nextURL: URL?
        var visitedURLs = Set<URL>()
        var knownIDs = Set<String>()
        do {
            repeat {
                let page = try await model.trackComments(for: track, pageURL: nextURL)
                try Task.checkCancellation()
                let additions = page.comments.filter {
                    $0.timestampMilliseconds != nil && knownIDs.insert($0.id).inserted
                }
                if !additions.isEmpty {
                    index = index.appending(additions)
                }
                nextURL = page.nextURL
                if let nextURL, !visitedURLs.insert(nextURL).inserted { break }
            } while nextURL != nil
        } catch {
            // Comments are optional; keep any pages already loaded.
        }
    }
}

// Only this small subtree observes the playback clock. Publish changes to the
// selected ID, not every clock tick, to the marker layer.
private struct WaveformCommentPlaybackObserver: View {
    let index: WaveformCommentIndex
    let playback: PlaybackController
    let trackURN: String
    @Binding var activeID: String?

    var body: some View {
        let nextID = playback.currentTrack?.urn == trackURN && playback.isPlaying
            ? index.playbackCommentID(at: playback.currentTime) : nil
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: nextID, initial: true) { _, value in
                if activeID != value { activeID = value }
            }
    }
}

private struct WaveformCommentMarkers: View, Equatable {
    let index: WaveformCommentIndex
    let model: AppModel
    let duration: Double
    let showsComments: Bool
    let playbackID: String?
    @Binding var seekRequest: Double?

    static func == (lhs: Self, rhs: Self) -> Bool {
        // The seek binding always addresses the owning view's same State.
        // Avoid passing its changing waveform/seek closure into this boundary.
        lhs.index === rhs.index && lhs.model === rhs.model
            && lhs.duration == rhs.duration && lhs.showsComments == rhs.showsComments
            && lhs.playbackID == rhs.playbackID
    }

    var body: some View {
        WaveformCommentMarkersContent(
            index: index,
            model: model,
            duration: duration,
            showsComments: showsComments,
            playbackID: playbackID,
            seekRequest: $seekRequest
        )
    }
}

// Keep local interaction state below the equality boundary. Hover, keyboard
// focus and environment changes must update this subtree independently of
// whether the playback inputs changed.
private struct WaveformCommentMarkersContent: View {
    let index: WaveformCommentIndex
    let model: AppModel
    let duration: Double
    let showsComments: Bool
    let playbackID: String?
    @Binding var seekRequest: Double?

    @State private var hoveredID: String?
    @FocusState private var focusedID: String?
    @Environment(\.contentHoverEnabled) private var contentHoverEnabled
    @Environment(\.contentHoverSuppression) private var hoverSuppression
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let interactionID = (hoveredID != nil && isHoverAllowed ? hoveredID : nil) ?? focusedID
            let width = proxy.size.width
            let comments = index.visibleComments(duration: duration)
            let interactionX = comments.first { $0.id == interactionID }
                .map { position(for: $0, width: width) }
            let commentID = interactionID ?? playbackID
            ZStack(alignment: .topLeading) {
                ForEach(comments) { comment in
                    let distance = interactionX.map { abs(position(for: comment, width: width) - $0) }
                    let proximity = distance.map {
                        let strength = max(0, 1 - $0 / 72)
                        return strength * strength * strength
                    } ?? 0
                    marker(
                        comment, width: width,
                        isActive: comment.id == interactionID || comment.id == playbackID,
                        showsComment: comment.id == commentID,
                        proximity: proximity
                    )
                        .modifier(FadeInOnAppear())
                        .scaleEffect(showsComments || reduceMotion ? 1 : 0.6)
                        .animation(
                            reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15),
                            value: showsComments
                        )
                        .position(x: position(for: comment, width: width), y: proxy.size.height / 2)
                        // Keep active avatars above neighbors, with interaction above playback.
                        .zIndex(comment.id == interactionID ? 2 : (comment.id == playbackID ? 1 : 0))
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard isHoverAllowed else { return }
                    // Select by distance, independent of the avatars' overlap and
                    // the active avatar's larger size and higher drawing order.
                    let nextID = index.hoverCommentID(
                        at: location.x, width: width, duration: duration
                    )
                    if hoveredID != nextID { hoveredID = nextID }
                case .ended:
                    hoveredID = nil
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: interactionID)
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: playbackID)
        }
        .opacity(showsComments ? 1 : 0)
        .allowsHitTesting(showsComments)
        .accessibilityHidden(!showsComments)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsComments)
        .onChange(of: showsComments) { _, visible in
            if !visible {
                hoveredID = nil
                focusedID = nil
            }
        }
        .onChange(of: hoveredID != nil && isHoverAllowed) { _, enabled in
            if !enabled {
                hoveredID = nil
            }
        }
        .onDisappear {
            hoveredID = nil
        }
    }

    private var isHoverAllowed: Bool {
        contentHoverEnabled && hoverSuppression?.isSuppressed != true
    }

    private func marker(
        _ comment: SoundCloudComment, width: CGFloat, isActive: Bool,
        showsComment: Bool, proximity: CGFloat
    ) -> some View {
        let x = position(for: comment, width: width)
        let textOnLeft = x > width / 2
        let textWidth = min(280, max(0, (textOnLeft ? x : width - x) + 16))
        return Button {
            guard duration > 0 else { return }
            seekRequest = seconds(for: comment) / duration
        } label: {
            TrackArtworkView(
                artworkURL: comment.user?.avatarURL,
                loader: model.artworkLoader,
                size: 32,
                showsBorder: false,
                animatesChanges: true,
                showsPlaceholderIcon: false
            )
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
            .overlay { Circle().fill(.black.opacity(isActive ? 0 : 0.5)) }
            .shadow(color: .black.opacity(isActive ? 0.4 : 0), radius: 5, y: 2)
            // Nearby avatars grow from 16 to 30 points; the active one reaches 32.
            .scaleEffect((isActive ? 32 : 16 + 14 * proximity) / 32)
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($focusedID, equals: comment.id)
        .overlay(alignment: textOnLeft ? .topTrailing : .topLeading) {
            if showsComment, textWidth > 0 {
                Text(comment.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: textWidth)
                    .fixedSize(horizontal: true, vertical: true)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.primary.opacity(0.2), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    .offset(y: 38)
                    .transition(.opacity.combined(with: .scale(
                        scale: 0.85, anchor: textOnLeft ? .topTrailing : .topLeading
                    )))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("\(comment.user?.username ?? "Unknown user"): \(comment.body)")
        .accessibilityValue(Duration.seconds(seconds(for: comment)).formatted(.time(pattern: .minuteSecond)))
        .accessibilityHint("Play from this comment")
    }

    private func seconds(for comment: SoundCloudComment) -> Double {
        Double(comment.timestampMilliseconds ?? 0) / 1_000
    }

    private func position(for comment: SoundCloudComment, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let inset = min(16, width / 2)
        return min(max(CGFloat(seconds(for: comment) / duration) * width, inset), width - inset)
    }
}
