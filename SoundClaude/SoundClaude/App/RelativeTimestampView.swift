import Foundation
import SwiftUI

struct RelativeTimestampView: View {
    var timestamp: String? = nil
    var date: Date? = nil
    let accessibilityPrefix: String
    var prefix: String? = nil
    var showsSeparator = true

    var hasTimestamp: Bool { parsedDate != nil }

    var body: some View {
        if let date = parsedDate {
            let relativeTime = date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            if showsSeparator {
                Text("·")
                    .accessibilityHidden(true)
            }
            if let prefix {
                Text(prefix)
                    .accessibilityHidden(true)
            }
            let fullDate = date.formatted(date: .complete, time: .shortened)
            Text(relativeTime)
                .accessibilityLabel("\(accessibilityPrefix) \(relativeTime)")
                .accessibilityValue(fullDate)
                .contentHelp(fullDate)
        }
    }

    private var parsedDate: Date? {
        date ?? timestamp.flatMap(SoundCloudDate.parse)
    }
}
