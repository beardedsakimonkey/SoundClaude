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
        SearchPill(text: genre, label: "Search tracks in genre: \(genre)", prefetch: .search(genre, .genre)) {
            searchGenre(genre)
        }
    }
}

struct TagPill: View {
    let tag: String
    @Environment(\.searchTag) private var searchTag

    var body: some View {
        SearchPill(text: tag, label: "Search tracks tagged: \(tag)", prefetch: .search(tag, .tag)) {
            searchTag(tag)
        }
    }
}

private struct SearchPill: View {
    let text: String
    let label: String
    let prefetch: PrefetchTarget
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            PillLabel(text: text, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .prefetch(prefetch, .pressOnly) { isHovering = $0 }
        .fixedSize()
        .accessibilityLabel(label)
        .contentHelp(label)
    }
}

struct PillLabel: View {
    enum Size {
        case regular
        case large
    }

    let text: String
    var isHovering = false
    var size: Size = .regular

    var body: some View {
        HStack(spacing: size == .large ? 3 : 2) {
            Text("#")
            Text(text)
                .foregroundStyle(size == .large || isHovering ? Color.primary : Color.secondary)
        }
        .font(size == .large ? .title3 : .caption)
        .foregroundStyle(isHovering ? Color.primary : Color.secondary)
        .padding(.horizontal, size == .large ? 12 : 8)
        .padding(.vertical, 4)
        .overlay {
            Capsule()
                .strokeBorder(.secondary.opacity(isHovering ? 0.7 : 0.35), lineWidth: 1)
        }
        .contentShape(Capsule())
    }
}
