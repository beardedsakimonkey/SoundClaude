import Foundation
import SwiftUI

struct RelativeTimestampView: View {
    var timestamp: String? = nil
    var date: Date? = nil
    let accessibilityPrefix: String
    var prefix: String? = nil
    var showsSeparator = true
    var systemImage: String? = nil

    @State private var isShowingDate = false

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
            Button { isShowingDate = true } label: {
                Text(prefix.map { "\($0) \(relativeTime)" } ?? relativeTime)
                    .accessibilityLabel("\(accessibilityPrefix) \(relativeTime)")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Show full date")
            .onContentHover { isShowingDate = $0 }
            .popover(isPresented: $isShowingDate, arrowEdge: .top) {
                Text(date.formatted(date: .complete, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .padding(12)
            }
            .onChange(of: date) { _, _ in isShowingDate = false }
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
