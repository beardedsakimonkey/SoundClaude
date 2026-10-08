import SwiftUI

struct DetailLikeButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isLiked: Bool
    var isUpdating = false
    var likeCount: Int? = nil
    var iconOnly = false
    let subject: String
    let action: () -> Void

    private var hasCount: Bool { !iconOnly && (likeCount ?? 0) != 0 }
    private var actionLabel: String { "\(isLiked ? "Unlike" : "Like") \(subject)" }

    var body: some View {
        Button {
            guard !isUpdating else { return }
            action()
        } label: {
            ZStack {
                label(systemImage: "heart")
                    .opacity(isLiked ? 0 : 1)
                    .accessibilityHidden(isLiked)
                label(systemImage: "heart.fill")
                    .foregroundStyle(Color.accentColor)
                    .opacity(isLiked ? 1 : 0)
                    .accessibilityHidden(!isLiked)
            }
            .labelStyle(.titleAndIcon)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, hasCount ? 24 : 0)
            .frame(width: hasCount ? nil : 44)
            .frame(minHeight: 24)
        }
        .buttonStyle(TrackActionButtonStyle(
            fill: isLiked ? .accentColor.opacity(0.12) : .primary.opacity(0.12)
        ))
        // Keep the button enabled so a pending request cannot interrupt its release spring.
        .opacity(isUpdating ? 0.5 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isLiked)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isUpdating)
        .contentHelp(actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityValue(isUpdating ? "Updating" : (isLiked ? "Liked" : "Not liked"))
    }

    @ViewBuilder
    private func label(systemImage: String) -> some View {
        if hasCount, let likeCount {
            Label(likeCount.formatted(.number), systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
        }
    }
}

extension DetailLikeButton {
    // Reserve the button's layout here while the navigation host owns its visible view.
    func detailSlot(trackURN: String, isCollection: Bool = false) -> some View {
        hidden()
            .accessibilityHidden(true)
            .anchorPreference(key: DetailLikeButtonPreferenceKey.self, value: .bounds) {
                DetailLikeButtonSource(bounds: $0, trackURN: trackURN, isCollection: isCollection, button: self)
            }
    }
}

struct DetailLikeButtonSource {
    let bounds: Anchor<CGRect>
    let trackURN: String
    let isCollection: Bool
    let button: DetailLikeButton
}

struct DetailLikeButtonPreferenceKey: PreferenceKey {
    static let defaultValue: DetailLikeButtonSource? = nil

    static func reduce(value: inout DetailLikeButtonSource?, nextValue: () -> DetailLikeButtonSource?) {
        value = nextValue() ?? value
    }
}

struct DetailLikeButtonOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(DetailLikeButtonPreferenceKey.self) { source in
            GeometryReader { geometry in
                if let source {
                    let bounds = geometry[source.bounds]
                    source.button
                        .modifier(FadeInOnAppear())
                        .transition(.identity)
                        .geometryGroup()
                        .frame(width: bounds.width, height: bounds.height)
                        .position(x: bounds.midX, y: bounds.midY)
                        .modifier(DetailNavigationAnimation(
                            trackURN: source.trackURN, isCollection: source.isCollection
                        ))
                }
            }
            .clipped()
        }
    }
}
