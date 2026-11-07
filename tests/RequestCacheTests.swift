import Foundation

// Holds fetches open until released, so tests control when a request finishes.
@MainActor
final class Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var fetches = 0

    func fetch(_ value: String) async -> String {
        fetches += 1
        await withCheckedContinuation { waiting.append($0) }
        return value
    }

    func release() {
        let continuations = waiting
        waiting.removeAll()
        continuations.forEach { $0.resume() }
    }

    var waitingCount: Int { waiting.count }
}

struct Failure: Error {}

@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@main
struct RequestCacheTests {
    @MainActor
    static func main() async throws {
        try await sharesOneRequest()
        try await callerCancellationKeepsRequest()
        try await removeDuringRequestSkipsCaching()
        try await resetCancelsRequest()
        try await failureAllowsRetry()
        try await insertReplacesRequest()
        try await cachesOptionalNil()
        print("RequestCache tests passed")
    }

    @MainActor
    static func sharesOneRequest() async throws {
        let cache = RequestCache<NSString, String>(name: "Test", countLimit: 10)
        let gate = Gate()
        async let first = cache.value(for: "a") { await gate.fetch("one") }
        async let second = cache.value(for: "a") { await gate.fetch("two") }
        await settle()
        precondition(gate.fetches == 1, "the second caller should join the first request")
        gate.release()
        let values = try await [first, second]
        precondition(values == ["one", "one"])
        precondition(cache.cached("a") == "one")
    }

    @MainActor
    static func callerCancellationKeepsRequest() async throws {
        let cache = RequestCache<NSString, String>(name: "Test", countLimit: 10)
        let gate = Gate()
        let prefetch = Task { try await cache.value(for: "a") { await gate.fetch("one") } }
        await settle()
        prefetch.cancel()
        let page = Task { try await cache.value(for: "a") { await gate.fetch("two") } }
        await settle()
        precondition(gate.fetches == 1, "a cancelled caller should not cancel the shared request")
        gate.release()
        let pageValue = try await page.value
        precondition(pageValue == "one")
        if case .success = await prefetch.result {
            preconditionFailure("the cancelled caller should see its cancellation")
        }
        precondition(cache.cached("a") == "one", "the request should cache without any live caller")
    }

    @MainActor
    static func removeDuringRequestSkipsCaching() async throws {
        let cache = RequestCache<NSString, String>(name: "Test", countLimit: 10)
        let gate = Gate()
        let stale = Task { try await cache.value(for: "a") { await gate.fetch("stale") } }
        await settle()
        cache.remove("a")
        let fresh = Task { try await cache.value(for: "a") { await gate.fetch("fresh") } }
        await settle()
        precondition(gate.fetches == 2, "a removed key should start a new request")
        gate.release()
        let staleValue = try await stale.value
        let freshValue = try await fresh.value
        precondition(staleValue == "stale", "waiting callers still get the old response")
        precondition(freshValue == "fresh")
        precondition(cache.cached("a") == "fresh", "the removed request must not overwrite the new one")
    }

    @MainActor
    static func resetCancelsRequest() async throws {
        let cache = RequestCache<NSString, String>(name: "Test", countLimit: 10)
        let gate = Gate()
        let request = Task {
            try await cache.value(for: "a") {
                let value = await gate.fetch("old")
                try Task.checkCancellation()
                return value
            }
        }
        await settle()
        cache.reset()
        gate.release()
        if case .success = await request.result {
            preconditionFailure("reset should cancel the request")
        }
        precondition(cache.cached("a") == nil)
    }

    @MainActor
    static func failureAllowsRetry() async throws {
        let cache = RequestCache<NSString, String>(name: "Test", countLimit: 10)
        do {
            _ = try await cache.value(for: "a") { throw Failure() }
            preconditionFailure("the failure should reach the caller")
        } catch is Failure {}
        let retried = try await cache.value(for: "a") { "retried" }
        precondition(retried == "retried")
    }

    @MainActor
    static func insertReplacesRequest() async throws {
        let cache = RequestCache<NSString, String>(name: "Test", countLimit: 10)
        let gate = Gate()
        let request = Task { try await cache.value(for: "a") { await gate.fetch("old") } }
        await settle()
        cache.insert("inserted", forKey: "a")
        gate.release()
        _ = try await request.value
        precondition(cache.cached("a") == "inserted", "an in-flight request must not overwrite an insert")
    }

    @MainActor
    static func cachesOptionalNil() async throws {
        let cache = RequestCache<NSString, String?>(name: "Test", countLimit: 10)
        var fetches = 0
        for _ in 0..<2 {
            let value = try await cache.value(for: "a") { () -> String? in fetches += 1; return nil }
            precondition(value == nil)
        }
        precondition(fetches == 1, "a cached nil should not be fetched again")
        guard case .some(nil) = cache.cached("a") else { preconditionFailure("nil should be cached") }
    }
}
