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
        precondition(!entry.requestHeaders.contains(secret))
        precondition(entry.requestHeaders.contains("application/json"))
        precondition(entry.attempt == 2 && entry.result == "Pending")
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
            headerFields: ["Set-Cookie": secret, "Location": "https://example.com/\(secret)", "Retry-After": "1"])!
        store.finish(id, response: response, bytes: 10, duration: 0.5, error: nil)
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
        print("Network activity tests passed")
    }
}
