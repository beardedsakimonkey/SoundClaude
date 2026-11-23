import Foundation
import Observation

/// Counts notifications newer than the last ones seen. api-v2 keeps no read state,
/// so, as soundcloud.com does, the last-seen point is stored per account on this Mac.
@MainActor
@Observable
final class NotificationBadge {
    /// Unread notifications on the newest page, so at most a page's worth.
    private(set) var unreadCount = 0
    /// Every notification on the newest page is unread, and older pages may hold more.
    private(set) var hasMoreUnread = false
    /// While the notifications page is on screen, what it loads counts as seen.
    var isViewing: Bool { viewers > 0 }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var lastSeen: Date?
    @ObservationIgnored private var newest: Date?
    /// A count, since a page can appear before the one it replaces disappears.
    @ObservationIgnored private var viewers = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Takes the newest page of unfiltered notifications.
    func update(with page: SoundCloudNotificationPage, accountID: String) {
        if accountID != self.accountID {
            clear()
            self.accountID = accountID
            lastSeen = defaults.object(forKey: key(for: accountID)) as? Date
        }
        let dates = page.notifications.compactMap(\.createdAt)
        newest = dates.max()
        // On an account's first check, earlier notifications are not news.
        guard !isViewing, let lastSeen else {
            markSeen()
            return
        }
        unreadCount = dates.filter { $0 > lastSeen }.count
        hasMoreUnread = unreadCount > 0 && unreadCount == page.notifications.count && page.nextURL != nil
    }

    func beginViewing() {
        viewers += 1
        markSeen()
    }

    func endViewing() {
        viewers = max(viewers - 1, 0)
    }

    func markSeen() {
        guard let accountID else { return }
        let seen = max(lastSeen ?? .distantPast, newest ?? .distantPast)
        if seen != lastSeen {
            lastSeen = seen
            defaults.set(seen, forKey: key(for: accountID))
        }
        unreadCount = 0
        hasMoreUnread = false
    }

    /// Forgets the session's state; the stored last-seen points stay for the next sign-in.
    func clear() {
        accountID = nil
        lastSeen = nil
        newest = nil
        unreadCount = 0
        hasMoreUnread = false
    }

    private func key(for accountID: String) -> String {
        "notificationsLastSeen.\(accountID)"
    }
}
