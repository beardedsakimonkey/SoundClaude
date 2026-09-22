import SwiftUI

struct ExpandableDescriptionText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let description: ArtistMentionText

    private let collapsedLineLimit = 5
    private let opacity = 0.9

    @State private var isExpanded = false
    @State private var isHoveringToggle = false
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var isTruncated: Bool {
        !isExpanded && fullHeight > collapsedHeight
    }

    init(description: String, onSelectArtist: @escaping (SoundCloudUser) -> Void) {
        self.description = ArtistMentionText(description, onSelectArtist: onSelectArtist)
    }

    @ViewBuilder
    private var selectableDescription: some View {
        // Native text selection can draw outside the fade mask when activated.
        if isTruncated {
            description.textSelection(.disabled)
        } else {
            description.textSelection(.enabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            selectableDescription
                // Keep the full text laid out while its visible height animates.
                .lineLimit(fullHeight > 0 ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) {
                    // Measure both sizes at the current width, even while expanded.
                    ZStack(alignment: .topLeading) {
                        description
                            .lineLimit(collapsedLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { collapsedHeight = $0 }

                        description
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { fullHeight = $0 }
                    }
                    .textSelection(.disabled)
                    .hidden()
                    .accessibilityHidden(true)
                }
                .modifier(DescriptionHeight(height: isExpanded ? fullHeight : collapsedHeight))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isExpanded)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(opacity), location: 0),
                            .init(color: .black.opacity(opacity), location: 0.8),
                            .init(color: isTruncated ? .clear : .black.opacity(opacity), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            if isExpanded || isTruncated {
                Button(isExpanded ? "Show less" : "Show more") {
                    isExpanded.toggle()
                }
                .buttonStyle(.link)
                .fontWeight(.semibold)
                .brightness(isHoveringToggle ? 0.1 : 0)
                .opacity(isHoveringToggle ? 1 : 0.9)
                .onContentHover { isHoveringToggle = $0 }
                .accessibilityHint(isExpanded ? "Collapse description" : "Expand description")
            }
        }
    }
}

private struct DescriptionHeight: AnimatableModifier {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        // Update layout on each frame so lazy rows below move together, including
        // rows created while scrolling. Do not animate their individual positions.
        content
            .frame(height: height > 0 ? height : nil, alignment: .topLeading)
            .clipped()
            .transaction { $0.animation = nil }
    }
}
