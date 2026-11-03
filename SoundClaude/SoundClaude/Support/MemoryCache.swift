import Foundation

final class MemoryCache<Key: NSObject, Value> {
    private final class Entry: NSObject {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private let cache = NSCache<Key, Entry>()

    #if DEBUG
    // NSCache cannot enumerate its contents. Records hold entries weakly so the
    // inspector neither extends their lifetime nor affects eviction order.
    private struct Record {
        weak var entry: Entry?
        let label: String
        let cost: Int
        let insertedAt: Date
        var hits = 0
    }

    private let name: String
    private let lock = NSLock()
    private var records: [Key: Record] = [:]
    private var hits = 0
    private var misses = 0
    private var evictions = 0
    #endif

    /// `name` labels this cache in the debug inspector.
    init(name: String, countLimit: Int, totalCostLimit: Int = 0) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        #if DEBUG
        self.name = name
        MemoryCacheRegistry.shared.register(self)
        #endif
    }

    func value(forKey key: Key) -> Value? {
        let value = cache.object(forKey: key)?.value
        #if DEBUG
        lock.lock()
        if value == nil {
            misses += 1
        } else {
            hits += 1
            records[key]?.hits += 1
        }
        lock.unlock()
        #endif
        return value
    }

    func insert(_ value: Value, forKey key: Key, cost: Int = 0) {
        let entry = Entry(value)
        // Update the records first: a live entry released by the cache call
        // below was replaced or removed, and must not read as an eviction.
        #if DEBUG
        lock.lock()
        if let previous = records[key], previous.entry == nil { evictions += 1 }
        records[key] = Record(entry: entry, label: String(describing: key), cost: cost, insertedAt: Date())
        // Evicted records accumulate until counted, even if no inspector is open.
        if records.count > max(cache.countLimit, 64) * 2 { pruneRecords() }
        lock.unlock()
        #endif
        cache.setObject(entry, forKey: key, cost: cost)
    }

    func removeValue(forKey key: Key) {
        #if DEBUG
        lock.lock()
        if let record = records.removeValue(forKey: key), record.entry == nil { evictions += 1 }
        lock.unlock()
        #endif
        cache.removeObject(forKey: key)
    }

    func removeAll() {
        #if DEBUG
        lock.lock()
        pruneRecords()
        records.removeAll()
        lock.unlock()
        #endif
        cache.removeAllObjects()
    }

    #if DEBUG
    /// Requires `lock`. An entry that NSCache released without a removal call was evicted.
    private func pruneRecords() {
        for (key, record) in records where record.entry == nil {
            records[key] = nil
            evictions += 1
        }
    }
    #endif
}

#if DEBUG
struct MemoryCacheSnapshot: Identifiable, Equatable {
    struct Entry: Identifiable, Equatable {
        let id: String
        var label: String
        var summary = ""
        let cost: Int
        var insertedAt: Date?
        var hits: Int?
        let value: Any

        // Values are not comparable. The summary stands in for them, so an
        // unchanged poll does not invalidate the inspector's table.
        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id && lhs.label == rhs.label && lhs.summary == rhs.summary
                && lhs.cost == rhs.cost && lhs.insertedAt == rhs.insertedAt && lhs.hits == rhs.hits
        }
    }

    let id: String
    let name: String
    /// Zero means no limit, matching NSCache.
    var countLimit = 0
    var totalCostLimit = 0
    var hits = 0
    var misses = 0
    var evictions = 0
    var entries: [Entry]

    var totalCost: Int { entries.reduce(0) { $0 + $1.cost } }
}

private protocol MemoryCacheInspectable: AnyObject {
    func snapshot(id: String) -> MemoryCacheSnapshot
}

extension MemoryCache: MemoryCacheInspectable {
    fileprivate func snapshot(id: String) -> MemoryCacheSnapshot {
        lock.lock()
        defer { lock.unlock() }
        pruneRecords()
        var entries: [MemoryCacheSnapshot.Entry] = []
        for (key, record) in records {
            // The entry may be released between the prune and this read.
            guard let entry = record.entry else { continue }
            entries.append(MemoryCacheSnapshot.Entry(
                id: String(key.hash), label: record.label, cost: record.cost,
                insertedAt: record.insertedAt, hits: record.hits, value: entry.value
            ))
        }
        entries.sort { ($0.insertedAt ?? .distantPast) > ($1.insertedAt ?? .distantPast) }
        return MemoryCacheSnapshot(
            id: id, name: name, countLimit: cache.countLimit, totalCostLimit: cache.totalCostLimit,
            hits: hits, misses: misses, evictions: evictions, entries: entries
        )
    }
}

final class MemoryCacheRegistry {
    static let shared = MemoryCacheRegistry()

    private let lock = NSLock()
    private var caches: [(id: String, reference: () -> MemoryCacheInspectable?)] = []

    fileprivate func register(_ cache: MemoryCacheInspectable) {
        lock.lock()
        defer { lock.unlock() }
        caches.append((UUID().uuidString, { [weak cache] in cache }))
    }

    func snapshots() -> [MemoryCacheSnapshot] {
        lock.lock()
        caches.removeAll { $0.reference() == nil }
        let current = caches
        lock.unlock()
        return current.compactMap { $0.reference()?.snapshot(id: $0.id) }
    }
}
#endif
