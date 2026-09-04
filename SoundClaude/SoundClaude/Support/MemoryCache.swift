import Foundation

final class MemoryCache<Key: NSObject, Value> {
    private final class Entry: NSObject {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private let cache = NSCache<Key, Entry>()

    init(countLimit: Int, totalCostLimit: Int = 0) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func value(forKey key: Key) -> Value? {
        cache.object(forKey: key)?.value
    }

    func insert(_ value: Value, forKey key: Key, cost: Int = 0) {
        cache.setObject(Entry(value), forKey: key, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
