import Foundation

/// A memory cache that shares one request per key, so a prefetch and the page it
/// warms await the same response. Cancelling a caller does not cancel the request.
@MainActor
final class RequestCache<Key: NSObject, Value> {
    private struct Request {
        let id: UUID
        let task: Task<Value, Error>
    }

    private let cache: MemoryCache<Key, Value>
    private let cost: (Value) -> Int
    private var requests: [Key: Request] = [:]

    /// `name` labels this cache in the debug inspector.
    init(
        name: String,
        countLimit: Int,
        totalCostLimit: Int = 0,
        cost: @escaping (Value) -> Int = { _ in 0 }
    ) {
        cache = MemoryCache(name: name, countLimit: countLimit, totalCostLimit: totalCostLimit)
        self.cost = cost
    }

    func cached(_ key: Key) -> Value? {
        cache.value(forKey: key)
    }

    func value(
        for key: Key,
        fetch: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        if let cached = cache.value(forKey: key) { return cached }
        let task = requests[key]?.task ?? start(key, fetch: fetch)
        let value = try await task.value
        try Task.checkCancellation()
        return value
    }

    /// Replaces the cached value. A request already in flight no longer updates it.
    func insert(_ value: Value, forKey key: Key) {
        requests[key] = nil
        cache.insert(value, forKey: key, cost: cost(value))
    }

    /// Callers already waiting still receive the in-flight response, but it is not cached.
    func remove(_ key: Key) {
        requests[key] = nil
        cache.removeValue(forKey: key)
    }

    /// Callers already waiting still receive in-flight responses, but they are not cached.
    func removeAll() {
        requests.removeAll()
        cache.removeAll()
    }

    /// Cancels in-flight requests, for a change of account.
    func reset() {
        for request in requests.values { request.task.cancel() }
        removeAll()
    }

    private func start(
        _ key: Key,
        fetch: @escaping @MainActor () async throws -> Value
    ) -> Task<Value, Error> {
        let id = UUID()
        // Cache in the request rather than in a caller, so the value is stored
        // as the request finishes, even if every caller has been cancelled.
        let task = Task { [weak self] in
            do {
                let value = try await fetch()
                if let self, requests[key]?.id == id {
                    requests[key] = nil
                    cache.insert(value, forKey: key, cost: cost(value))
                }
                return value
            } catch {
                if let self, requests[key]?.id == id { requests[key] = nil }
                throw error
            }
        }
        requests[key] = Request(id: id, task: task)
        return task
    }
}
