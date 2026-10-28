#if DEBUG
import SwiftUI
import Foundation

struct NetworkActivityEntry: Identifiable {
    let id: UUID
    let started: Date
    let sequence: Int
    let startOffset: TimeInterval
    let startedUptime: TimeInterval
    let method: String
    let url: String
    let category: String
    let attempt: Int
    let requestHeaders: String
    var status: Int?
    var duration: TimeInterval?
    var bytes = 0
    var responseHeaders = ""
    var error: String?

    func elapsed(at uptime: TimeInterval) -> TimeInterval {
        duration ?? max(0, uptime - startedUptime)
    }

    var failed: Bool { error != nil || (status ?? 0) >= 400 }
    var result: String { error ?? status.map(String.init) ?? "Pending" }
}

/// Only sanitized metadata is retained. Bodies and arbitrary headers can contain credentials.
enum NetworkActivitySanitizer {
    static func url(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "Unknown URL"
        }
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.map {
            URLQueryItem(name: $0.name, value: isPagingValue($0) ? $0.value : "REDACTED")
        }
        return parts.string ?? "Unknown URL"
    }

    /// Paging parameters identify which caller made a request. Only short numeric
    /// or boolean values are shown, so an opaque cursor stays redacted.
    private static func isPagingValue(_ item: URLQueryItem) -> Bool {
        let allowed: Set<String> = ["limit", "offset", "linked_partitioning"]
        guard allowed.contains(item.name.lowercased()), let value = item.value,
              !value.isEmpty, value.count <= 10 else { return false }
        return value.allSatisfy(\.isASCII) && (value.allSatisfy(\.isNumber) || value == "true" || value == "false")
    }

    static func headers(_ headers: [String: String]) -> String {
        let allowed: Set<String> = ["accept", "content-type", "content-length", "retry-after"]
        return headers.sorted { $0.key < $1.key }.map { key, value in
            "\(key): \(allowed.contains(key.lowercased()) ? String(value.prefix(512)) : "[REDACTED]")"
        }.joined(separator: "\n")
    }
}

@MainActor
@Observable
final class NetworkActivityStore {
    static let shared = NetworkActivityStore()
    var isRecording = true
    private(set) var entries: [NetworkActivityEntry] = []

    private var origin: TimeInterval?
    private var nextSequence = 1

    func begin(_ request: URLRequest, attempt: Int,
               started: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UUID? {
        guard isRecording else { return nil }
        let id = UUID()
        if origin == nil { origin = uptime }
        let host = request.url?.host ?? ""
        let category = host == "api.soundcloud.com" ? "API"
            : host.contains("sndcdn.com") && request.value(forHTTPHeaderField: "Accept")?.contains("image/") == true
                ? "Artwork" : "Other"
        entries.insert(NetworkActivityEntry(
            id: id, started: started, sequence: nextSequence,
            startOffset: uptime - (origin ?? uptime), startedUptime: uptime, method: request.httpMethod ?? "GET",
            url: NetworkActivitySanitizer.url(request.url), category: category,
            attempt: attempt, requestHeaders: NetworkActivitySanitizer.headers(request.allHTTPHeaderFields ?? [:])
        ), at: 0)
        nextSequence += 1
        if entries.count > 500 { entries.removeLast(entries.count - 500) }
        return id
    }

    func finish(_ id: UUID?, response: URLResponse?, bytes: Int, duration: TimeInterval, error: String?) {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let response = response as? HTTPURLResponse
        entries[index].status = response?.statusCode
        entries[index].bytes = bytes
        entries[index].duration = duration
        entries[index].error = error
        let headers = (response?.allHeaderFields ?? [:]).reduce(into: [String: String]()) {
            $0[String(describing: $1.key)] = String(describing: $1.value)
        }
        entries[index].responseHeaders = NetworkActivitySanitizer.headers(headers)
    }

    func clear() {
        entries.removeAll()
        origin = nil
        nextSequence = 1
    }
}

struct NetworkActivityView: View {
    @State private var store = NetworkActivityStore.shared
    @State private var selection: UUID?
    @State private var filter = "All"
    @State private var search = ""

    private var entries: [NetworkActivityEntry] {
        store.entries.reversed().filter {
            (filter == "All" || (filter == "Failures" ? $0.failed : $0.category == filter))
                && (search.isEmpty || $0.url.localizedCaseInsensitiveContains(search)
                    || $0.method.localizedCaseInsensitiveContains(search))
        }
    }

    private func milliseconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f", interval * 1000)
    }

    private func waterfall(_ entry: NetworkActivityEntry, uptime: TimeInterval,
                           lower: TimeInterval, upper: TimeInterval) -> some View {
        GeometryReader { geometry in
            let span = max(upper - lower, 0.001)
            let x = max(0, (entry.startOffset - lower) / span * geometry.size.width)
            let width = entry.elapsed(at: uptime) / span * geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.05))
                RoundedRectangle(cornerRadius: 3)
                    .fill(entry.failed ? Color.red : entry.duration == nil ? Color.orange : Color.accentColor)
                    .frame(width: min(max(2, width), max(0, geometry.size.width - x)), height: 10)
                    .offset(x: x)
            }
        }
        .frame(height: 18)
        .help("Start +\(milliseconds(entry.startOffset)) ms · Duration \(milliseconds(entry.elapsed(at: uptime))) ms")
        .accessibilityLabel("Request \(entry.sequence), start \(milliseconds(entry.startOffset)) milliseconds, duration \(milliseconds(entry.elapsed(at: uptime))) milliseconds")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(["All", "API", "Artwork", "Other", "Failures"], id: \.self) { Text($0) }
                }.frame(width: 180)
                TextField("Filter by URL or method", text: $search)
                Button(store.isRecording ? "Pause" : "Resume") { store.isRecording.toggle() }
                Button("Clear") { store.clear(); selection = nil }
            }.padding(12)
            Text("Clear before opening a station. Rows show start order; overlapping bars show concurrent requests.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let uptime = ProcessInfo.processInfo.systemUptime
                let lower = store.entries.map(\.startOffset).min() ?? 0
                let upper = store.entries.map { $0.startOffset + $0.elapsed(at: uptime) }.max() ?? lower
                VStack(spacing: 4) {
                    Text(String(format: "Timeline: +%.0f to +%.0f ms · offsets from first request after Clear", lower * 1000, upper * 1000))
                        .font(.caption).foregroundStyle(.secondary)
                    Table(entries, selection: $selection) {
                        TableColumn("#") { Text(String($0.sequence)) }.width(40)
                        TableColumn("Start (ms)") { Text(milliseconds($0.startOffset)) }.width(85)
                        TableColumn("Method", value: \.method).width(60)
                        TableColumn("URL", value: \.url)
                        TableColumn("Status") { entry in
                            Text(entry.result).foregroundStyle(entry.failed ? .red : .primary)
                        }.width(90)
                        TableColumn("Waterfall") { entry in
                            waterfall(entry, uptime: uptime, lower: lower, upper: upper)
                        }.width(min: 180, ideal: 240)
                        TableColumn("Duration (ms)") { entry in
                            Text(milliseconds(entry.elapsed(at: uptime)) + (entry.duration == nil ? "…" : ""))
                        }.width(100)
                        TableColumn("Bytes") { Text(String($0.bytes)) }.width(65)
                        TableColumn("Attempt") { Text(String($0.attempt)) }.width(60)
                    }
                    .monospacedDigit()
                }
            }
            Divider()
            ScrollView {
                if let entry = store.entries.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(entry.method) \(entry.url)").fontWeight(.semibold)
                        Text("\(entry.category) · Attempt \(entry.attempt) · \(entry.result)")
                        Text("Started: \(entry.started.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))) · +\(milliseconds(entry.startOffset)) ms")
                        if let duration = entry.duration {
                            Text("Completed: +\(milliseconds(entry.startOffset + duration)) ms · Total: \(milliseconds(duration)) ms")
                        } else {
                            Text("Request in progress")
                        }
                        Text("Request headers\n\(entry.requestHeaders.isEmpty ? "None" : entry.requestHeaders)")
                        Text("Response headers\n\(entry.responseHeaders.isEmpty ? "None" : entry.responseHeaders)")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else {
                    Text("Select a request to inspect its details.")
                        .foregroundStyle(.secondary).padding()
                }
            }.frame(height: 180)
            HStack {
                Text("\(entries.count) shown · \(store.entries.count)/500 retained · \(store.isRecording ? "Recording" : "Paused")")
                Spacer()
                Text("Bodies omitted · Query values hidden · Audio downloads excluded")
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(minWidth: 950, minHeight: 500)
    }
}
#endif
