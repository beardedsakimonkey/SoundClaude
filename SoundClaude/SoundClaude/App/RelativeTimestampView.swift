import Foundation
import SwiftUI

struct RelativeTimestampView: View {
    var timestamp: String? = nil
    var date: Date? = nil
    let accessibilityPrefix: String
    var prefix: String? = nil
    var showsSeparator = true
    var systemImage: String? = nil

    var hasTimestamp: Bool { parsedDate != nil }

    var body: some View {
        if let date = parsedDate {
            let relativeTime = date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            if showsSeparator {
                Text("·")
                    .accessibilityHidden(true)
            }
            if let systemImage {
                Image(systemName: systemImage)
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
        if let date { return date }
        guard let timestamp else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: timestamp) { return date }

        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: timestamp) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
        return formatter.date(from: timestamp)
    }
}
