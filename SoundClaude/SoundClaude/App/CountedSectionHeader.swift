import SwiftUI

extension Font {
    static let sectionHeading = Font.title3.weight(.semibold)
}

struct CountedSectionHeader: View {
    let title: LocalizedStringKey
    let count: Int?
    var font: Font = .sectionHeading

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            if let count {
                Text("(\(count.formatted()))")
                    .foregroundStyle(.secondary)
                    .fontWeight(.regular)
            }
        }
        .font(font)
        .opacity(0.96)
    }
}
