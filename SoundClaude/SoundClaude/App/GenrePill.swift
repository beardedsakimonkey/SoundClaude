import SwiftUI

private struct GenreSearchActionKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var searchGenre: (String) -> Void {
        get { self[GenreSearchActionKey.self] }
        set { self[GenreSearchActionKey.self] = newValue }
    }
}

struct GenrePill: View {
    let genre: String
    @Environment(\.searchGenre) private var searchGenre

    var body: some View {
        Button { searchGenre(genre) } label: {
            HStack(spacing: 2) {
                Text("#")
                Text(genre)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay {
                Capsule()
                    .strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Search tracks in genre: \(genre)")
        .help("Search tracks in genre: \(genre)")
    }
}
