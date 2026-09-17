import Foundation

struct RecentSearchStore {
    var defaults: UserDefaults = .standard
    static let limit = 10

    func restore(for user: SoundCloudUser) -> [String] {
        defaults.stringArray(forKey: key(for: user)) ?? []
    }

    @discardableResult
    func record(_ text: String, for user: SoundCloudUser) -> [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var searches = restore(for: user)
        guard !query.isEmpty else { return searches }
        searches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        searches.insert(query, at: 0)
        searches = Array(searches.prefix(Self.limit))
        defaults.set(searches, forKey: key(for: user))
        return searches
    }

    @discardableResult
    func remove(_ query: String, for user: SoundCloudUser) -> [String] {
        let searches = restore(for: user).filter { $0 != query }
        defaults.set(searches, forKey: key(for: user))
        return searches
    }

    func clear(for user: SoundCloudUser) {
        defaults.removeObject(forKey: key(for: user))
    }

    private func key(for user: SoundCloudUser) -> String {
        "search.recent.\(user.urn ?? user.permalinkURL.absoluteString)"
    }
}
