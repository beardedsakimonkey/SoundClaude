import SwiftUI

struct EmptyStateView: View {
    private let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        ContentUnavailableView {
            Text(title)
                .font(.body.weight(.regular))
                .foregroundStyle(.secondary)
        }
    }
}
