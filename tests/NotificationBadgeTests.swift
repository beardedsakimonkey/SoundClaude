import Foundation

@main
struct NotificationBadgeTests {
    @MainActor static func main() {
        let suite = "NotificationBadgeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let user = SoundCloudUser(
            urn: "soundcloud:users:7", username: "Fan", avatarURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/fan")!
        )
        let start = Date(timeIntervalSince1970: 1_000_000)
        func page(_ minutes: [Int], hasMore: Bool = false) -> SoundCloudNotificationPage {
            SoundCloudNotificationPage(
                notifications: minutes.sorted(by: >).map { minute in
                    SoundCloudNotification(
                        id: "n\(minute)", kind: .follow, user: user,
                        createdAt: start.addingTimeInterval(Double(minute) * 60),
                        content: nil, comment: nil
                    )
                },
                nextURL: hasMore ? URL(string: "https://api-v2.soundcloud.com/activities?offset=x") : nil
            )
        }

        // An account's first check treats what is already there as seen.
        let badge = NotificationBadge(defaults: defaults)
        badge.update(with: page([1, 2, 3]), accountID: "a")
        precondition(badge.unreadCount == 0 && !badge.hasMoreUnread)

        badge.update(with: page([1, 2, 3, 4, 5]), accountID: "a")
        precondition(badge.unreadCount == 2 && !badge.hasMoreUnread)

        // The last-seen point survives a relaunch.
        let relaunched = NotificationBadge(defaults: defaults)
        relaunched.update(with: page([2, 3, 4, 5, 6]), accountID: "a")
        precondition(relaunched.unreadCount == 3)

        // A page of nothing but unread ones may hide more on later pages.
        relaunched.update(with: page([4, 5, 6], hasMore: true), accountID: "a")
        precondition(relaunched.unreadCount == 3 && relaunched.hasMoreUnread)

        relaunched.markSeen()
        precondition(relaunched.unreadCount == 0 && !relaunched.hasMoreUnread)
        relaunched.update(with: page([4, 5, 6]), accountID: "a")
        precondition(relaunched.unreadCount == 0)

        // While the page is open, what loads counts as seen, including afterwards.
        relaunched.beginViewing()
        relaunched.update(with: page([5, 6, 7]), accountID: "a")
        precondition(relaunched.unreadCount == 0 && relaunched.isViewing)
        relaunched.endViewing()
        precondition(!relaunched.isViewing)
        relaunched.update(with: page([5, 6, 7]), accountID: "a")
        precondition(relaunched.unreadCount == 0)

        // Overlapping appearances keep the page counted as open.
        relaunched.beginViewing()
        relaunched.beginViewing()
        relaunched.endViewing()
        precondition(relaunched.isViewing)
        relaunched.endViewing()
        relaunched.endViewing()
        precondition(!relaunched.isViewing)

        // Accounts are tracked separately, and an account with no notifications yet
        // counts the first ones that arrive.
        relaunched.update(with: page([]), accountID: "b")
        precondition(relaunched.unreadCount == 0)
        relaunched.update(with: page([1]), accountID: "b")
        precondition(relaunched.unreadCount == 1)
        relaunched.update(with: page([5, 6, 7, 8]), accountID: "a")
        precondition(relaunched.unreadCount == 1)

        relaunched.clear()
        precondition(relaunched.unreadCount == 0)
        relaunched.update(with: page([5, 6, 7, 8]), accountID: "a")
        precondition(relaunched.unreadCount == 1)

        print("Notification badge counting, persistence, viewing, and account checks passed")
    }
}
