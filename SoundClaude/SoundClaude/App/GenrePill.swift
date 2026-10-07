import SwiftUI

private struct GenreSearchActionKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

private struct TagSearchActionKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var searchTag: (String) -> Void {
        get { self[TagSearchActionKey.self] }
        set { self[TagSearchActionKey.self] = newValue }
    }

    var searchGenre: (String) -> Void {
        get { self[GenreSearchActionKey.self] }
        set { self[GenreSearchActionKey.self] = newValue }
    }
}

struct GenrePill: View {
    let genre: String
    @Environment(\.searchGenre) private var searchGenre

    var body: some View {
        SearchPill(text: genre, label: "Search tracks in genre: \(genre)") {
            searchGenre(genre)
        }
    }
}

struct TagPill: View {
    let tag: String
    @Environment(\.searchTag) private var searchTag

    var body: some View {
        SearchPill(text: tag, label: "Search tracks tagged: \(tag)") {
            searchTag(tag)
        }
    }
}

private struct SearchPill: View {
    let text: String
    let label: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text("#")
                Text(text)
            }
            .font(.caption)
            .foregroundStyle(isHovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay {
                Capsule()
                    .strokeBorder(.secondary.opacity(isHovering ? 0.7 : 0.35), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onContentHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHovering)
        .fixedSize()
        .accessibilityLabel(label)
        .contentHelp(label)
    }
}

/// Wrap tags onto a new row when they exceed the available width.
struct TagLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + layout.origins[index].x, y: bounds.minY + layout.origins[index].y),
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let availableWidth = width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            contentWidth = max(contentWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width ?? contentWidth, height: y + rowHeight), origins)
    }
}

