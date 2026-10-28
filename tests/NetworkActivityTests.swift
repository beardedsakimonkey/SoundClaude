import Foundation

@main
struct NetworkActivityTests {
    @MainActor
    static func main() {
        let secret = "test-secret-value"
        var request = URLRequest(url: URL(string: "https://user:password@api.soundcloud.com/tracks?access_token=\(secret)&q=private#fragment")!)
        request.setValue("OAuth \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue(secret, forHTTPHeaderField: "X-Custom-Credential")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(secret.utf8)
        let store = NetworkActivityStore()
        let id = store.begin(request, attempt: 2)!
        let entry = store.entries[0]
        precondition(!entry.url.contains(secret) && !entry.url.contains("password") && !entry.url.contains("fragment"))
        precondition(!entry.url.contains("private"))
        let paged = NetworkActivitySanitizer.url(URL(string: "https://api.soundcloud.com/tracks?limit=50&offset=abc123cursor&linked_partitioning=true&q=1")!)
        precondition(paged.contains("limit=50") && paged.contains("linked_partitioning=true"))
        precondition(paged.contains("offset=REDACTED") && paged.contains("q=REDACTED"))
        precondition(!entry.requestHeaders.contains(secret))
        precondition(entry.requestHeaders.contains("application/json"))
        precondition(entry.attempt == 2 && entry.result == "Pending")
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
            headerFields: ["Set-Cookie": secret, "Location": "https://example.com/\(secret)", "Retry-After": "1"])!
        let body = Data(#"{"error":"Too many requests","retry":true}"#.utf8)
        store.finish(id, response: response, bytes: 10, duration: 0.5, error: nil, body: body)
        let preview = store.entries[0].responseBody
        precondition(preview.contains("\n") && preview.contains("Too many requests"))
        precondition((try? JSONSerialization.jsonObject(with: Data(preview.utf8))) != nil)
        precondition(NetworkResponseBody.preview(Data("Service unavailable".utf8), mimeType: "text/plain") == "Service unavailable")
        precondition(NetworkResponseBody.preview(Data(), mimeType: nil) == "Empty response body")
        precondition(NetworkResponseBody.preview(nil, mimeType: nil) == "No response body available")
        precondition(NetworkResponseBody.preview(Data([0xff, 0x00]), mimeType: nil).contains("Binary"))
        precondition(NetworkResponseBody.preview(Data("GIF89a".utf8), mimeType: "image/gif").contains("Binary"))
        let large = Data(repeating: 65, count: NetworkResponseBody.maximumBytes + 100)
        let truncated = NetworkResponseBody.preview(large, mimeType: "text/plain")
        precondition(truncated.contains("[Truncated:") && truncated.utf8.count < large.count)
        let unicode = Data((String(repeating: "A", count: NetworkResponseBody.maximumBytes - 1) + "😀").utf8)
        precondition(NetworkResponseBody.preview(unicode, mimeType: "text/plain").contains("[Truncated:"))
        precondition(store.entries[0].failed && store.entries[0].bytes == 10)
        precondition(!store.entries[0].responseHeaders.contains(secret))
        store.isRecording = false
        precondition(store.begin(request, attempt: 1) == nil)
        store.clear()
        store.finish(id, response: response, bytes: 10, duration: 1, error: nil)
        precondition(store.entries.isEmpty, "Cleared requests must not reappear on completion")
        store.isRecording = true
        for _ in 0..<501 { _ = store.begin(request, attempt: 1) }
        precondition(store.entries.count == 500)
        let pending = store.entries[0].id
        store.isRecording = false
        store.finish(pending, response: nil, bytes: 0, duration: 1, error: "Error -999")
        precondition(store.entries[0].failed, "Pending requests must finish while paused")
        // Shared offsets preserve overlaps and gaps regardless of completion order.
        store.clear()
        store.isRecording = true
        let first = store.begin(request, attempt: 1, uptime: 100)!
        let second = store.begin(request, attempt: 1, uptime: 100.1)!
        store.finish(second, response: response, bytes: 10, duration: 0.2, error: nil)
        store.finish(first, response: response, bytes: 10, duration: 0.5, error: nil)
        _ = store.begin(request, attempt: 1, uptime: 101)
        let chronological = Array(store.entries.reversed())
        precondition(chronological.map(\.sequence) == [1, 2, 3])
        precondition(chronological[0].startOffset == 0)
        precondition(abs(chronological[1].startOffset - 0.1) < 0.000001)
        precondition(chronological[1].startOffset < chronological[0].duration!)
        precondition(chronological[2].startOffset > chronological[0].duration!)
        precondition(chronological[0].elapsed(at: 102) == 0.5)
        precondition(chronological[2].elapsed(at: 102) == 1)
        store.clear()
        _ = store.begin(request, attempt: 1, uptime: 200)
        precondition(store.entries[0].sequence == 1 && store.entries[0].startOffset == 0)
        print("Network activity tests passed")
    }
}
