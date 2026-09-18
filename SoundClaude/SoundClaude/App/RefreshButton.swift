import SwiftUI

struct RefreshButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.clockwise")
                .labelStyle(.iconOnly)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary.opacity(isLoading ? 0.3 : isHovered ? 1 : 0.6))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onContentHover { isHovered = $0 }
        .help(title)
    }
}
