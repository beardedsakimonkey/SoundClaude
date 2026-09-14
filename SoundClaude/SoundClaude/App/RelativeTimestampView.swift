import Foundation
import SwiftUI

struct RelativeTimestampView: View {
    let timestamp: String?
    let accessibilityPrefix: String
    var prefix: String? = nil

    var body: some View {
        if let date = parsedDate {
            let relativeTime = date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            Text("·")
                .accessibilityHidden(true)
            Text(prefix.map { "\($0) \(relativeTime)" } ?? relativeTime)
                .help(date.formatted(date: .abbreviated, time: .shortened))
                .accessibilityLabel("\(accessibilityPrefix) \(relativeTime)")
        }
    }

    private var parsedDate: Date? {
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
