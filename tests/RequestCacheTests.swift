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

// A clock the tests advance by hand.
final class TestClock {
    private(set) var now = ContinuousClock.now

    func advance(by duration: Duration) {
        now += duration
    }
}

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
        try await expiredValueIsFetchedAgain()
        try await insertRestartsExpiry()
        try await nilMaxAgeNeverExpires()
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

    @MainActor
    static func expiredValueIsFetchedAgain() async throws {
        let clock = TestClock()
        let cache = RequestCache<NSString, String>(
            name: "Test", countLimit: 10, maxAge: .seconds(60), now: { clock.now }
        )
        var fetches = 0
        let fetch: @MainActor () async throws -> String = { fetches += 1; return "value \(fetches)" }
        _ = try await cache.value(for: "a", fetch: fetch)
        clock.advance(by: .seconds(59))
        let fresh = try await cache.value(for: "a", fetch: fetch)
        precondition(fresh == "value 1" && fetches == 1, "a value within its lifetime should be reused")
        clock.advance(by: .seconds(1))
        precondition(cache.cached("a") == nil, "an expired value should not be readable")
        let refetched = try await cache.value(for: "a", fetch: fetch)
        precondition(refetched == "value 2" && fetches == 2, "an expired value should be fetched again")
        precondition(cache.cached("a") == "value 2")
    }

    @MainActor
    static func insertRestartsExpiry() async throws {
        let clock = TestClock()
        let cache = RequestCache<NSString, String>(
            name: "Test", countLimit: 10, maxAge: .seconds(60), now: { clock.now }
        )
        cache.insert("old", forKey: "a")
        clock.advance(by: .seconds(45))
        cache.insert("new", forKey: "a")
        clock.advance(by: .seconds(45))
        precondition(cache.cached("a") == "new", "a replaced value should live from its own insertion")
    }

    @MainActor
    static func nilMaxAgeNeverExpires() async throws {
        let clock = TestClock()
        let cache = RequestCache<NSString, String>(
            name: "Test", countLimit: 10, maxAge: nil, now: { clock.now }
        )
        cache.insert("kept", forKey: "a")
        clock.advance(by: .seconds(365 * 24 * 60 * 60))
        precondition(cache.cached("a") == "kept")
    }
}
