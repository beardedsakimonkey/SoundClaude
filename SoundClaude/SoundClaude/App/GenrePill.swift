import SwiftUI

struct GenrePill: View {
    let genre: String

    var body: some View {
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
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Genre: \(genre)")
    }
}
