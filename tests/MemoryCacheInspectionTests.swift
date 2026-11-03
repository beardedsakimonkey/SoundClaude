import Foundation

private final class Tracked {}

@main
struct MemoryCacheInspectionTests {
    static func main() {
        let cache = MemoryCache<NSString, Tracked>(name: "Test", countLimit: 2)
        func snapshot() -> MemoryCacheSnapshot {
            MemoryCacheRegistry.shared.snapshots().first { $0.name == "Test" }!
        }

        cache.insert(Tracked(), forKey: "a", cost: 5)
        precondition(cache.value(forKey: "a") != nil)
        precondition(cache.value(forKey: "missing") == nil)
        var current = snapshot()
        precondition(current.countLimit == 2 && current.hits == 1 && current.misses == 1)
        precondition(current.entries.count == 1 && current.entries[0].label == "a")
        precondition(current.entries[0].hits == 1 && current.totalCost == 5)

        // Replacing or removing an entry is not an eviction.
        cache.insert(Tracked(), forKey: "a")
        cache.removeValue(forKey: "a")
        current = snapshot()
        precondition(current.entries.isEmpty && current.evictions == 0)

        // Entries past the limit leave the snapshot and count as evictions.
        for key in ["b", "c", "d"] { cache.insert(Tracked(), forKey: key as NSString) }
        current = snapshot()
        precondition(current.entries.count == 2 && current.evictions == 1)

        cache.removeAll()
        current = snapshot()
        precondition(current.entries.isEmpty && current.evictions == 1)

        // Inspection must not keep a removed value alive.
        weak var released: Tracked?
        autoreleasepool {
            let value = Tracked()
            released = value
            cache.insert(value, forKey: "e")
            _ = snapshot()
            cache.removeAll()
        }
        precondition(released == nil)

        print("Memory cache inspection tests passed")
    }
}
