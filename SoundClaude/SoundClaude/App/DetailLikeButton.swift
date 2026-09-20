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
        .help(actionLabel)
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
