import SwiftUI

struct DetailLikeButton: View {
    let isLiked: Bool
    var likeCount: Int? = nil
    let subject: String
    let action: () -> Void

    private var hasCount: Bool { (likeCount ?? 0) != 0 }
    private var actionLabel: String { "\(isLiked ? "Unlike" : "Like") \(subject)" }

    var body: some View {
        Button(action: action) {
            ZStack {
                label(systemImage: "heart")
                    .opacity(isLiked ? 0 : 1)
                    .accessibilityHidden(isLiked)
                label(systemImage: "heart.fill")
                    .foregroundStyle(.orange)
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
        .help(actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityValue(isLiked ? "Liked" : "Not liked")
    }

    @ViewBuilder
    private func label(systemImage: String) -> some View {
        if let likeCount, likeCount != 0 {
            Label(likeCount.formatted(.number), systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
        }
    }
}
