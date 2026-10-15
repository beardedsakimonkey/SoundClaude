#if DEBUG
import SwiftUI
import Foundation

struct NetworkActivityEntry: Identifiable {
    let id: UUID
    let started: Date
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

    func begin(_ request: URLRequest, attempt: Int) -> UUID? {
        guard isRecording else { return nil }
        let id = UUID()
        let host = request.url?.host ?? ""
        let category = host == "api.soundcloud.com" ? "API"
            : host.contains("sndcdn.com") && request.value(forHTTPHeaderField: "Accept")?.contains("image/") == true
                ? "Artwork" : "Other"
        entries.insert(NetworkActivityEntry(
            id: id, started: Date(), method: request.httpMethod ?? "GET",
            url: NetworkActivitySanitizer.url(request.url), category: category,
            attempt: attempt, requestHeaders: NetworkActivitySanitizer.headers(request.allHTTPHeaderFields ?? [:])
        ), at: 0)
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

    func clear() { entries.removeAll() }
}

struct NetworkActivityView: View {
    @State private var store = NetworkActivityStore.shared
    @State private var selection: UUID?
    @State private var filter = "All"
    @State private var search = ""

    private var entries: [NetworkActivityEntry] {
        store.entries.filter {
            (filter == "All" || (filter == "Failures" ? $0.failed : $0.category == filter))
                && (search.isEmpty || $0.url.localizedCaseInsensitiveContains(search)
                    || $0.method.localizedCaseInsensitiveContains(search))
        }
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
            Table(entries, selection: $selection) {
                TableColumn("Time") { Text($0.started, style: .time) }.width(85)
                TableColumn("Method", value: \.method).width(60)
                TableColumn("URL", value: \.url)
                TableColumn("Status") { entry in
                    Text(entry.result).foregroundStyle(entry.failed ? .red : .primary)
                }.width(90)
                TableColumn("Time (ms)") { entry in
                    Text(entry.duration.map { String(format: "%.0f", $0 * 1000) } ?? "—")
                }.width(75)
                TableColumn("Bytes") { Text(String($0.bytes)) }.width(75)
                TableColumn("Attempt") { Text(String($0.attempt)) }.width(60)
            }
            Divider()
            ScrollView {
                if let entry = store.entries.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(entry.method) \(entry.url)").fontWeight(.semibold)
                        Text("\(entry.category) · Attempt \(entry.attempt) · \(entry.result)")
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
