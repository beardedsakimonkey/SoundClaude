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
                    .strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onContentHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHovering)
        .fixedSize()
        .accessibilityLabel(label)
        .help(label)
    }
}
