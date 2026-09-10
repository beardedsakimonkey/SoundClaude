import SwiftUI

struct CountedSectionHeader: View {
    let title: LocalizedStringKey
    let count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            if let count {
                Text("(\(count.formatted()))")
                    .foregroundStyle(.secondary)
                    .fontWeight(.regular)
            }
        }
        .font(.headline)
    }
}
