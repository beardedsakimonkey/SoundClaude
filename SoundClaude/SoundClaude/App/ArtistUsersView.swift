import SwiftUI

struct ArtistUsersView: View {
    let artist: SoundCloudUser
    let list: ArtistUserList
    @ObservedObject var model: AppModel
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var users: [SoundCloudUser] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var totalUserCount: Int?

    private var title: String {
        list == .following
            ? "\(artist.username) is following"
            : "Followers of \(artist.username)"
    }

    private var userCount: Int? {
        if hasLoaded, nextPageURL == nil { return users.count }
        return totalUserCount
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                    if let userCount {
                        Text("(\(userCount.formatted()))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.title2)

                UserGridView(
                    users: users,
                    artworkLoader: model.artworkLoader,
                    onSelectArtist: onSelectArtist
                )

                if let errorMessage {
                    VStack(spacing: 8) {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await loadPage() } }
                            .disabled(isLoading)
                    }
                    .frame(maxWidth: .infinity)
                } else if !hasLoaded || nextPageURL != nil {
                    ProgressView()
                        .accessibilityLabel("Loading \(list.title.lowercased())")
                        .frame(maxWidth: .infinity)
                        .task(id: nextPageURL) { await loadPage() }
                } else if users.isEmpty {
                    EmptyStateView(list == .followers ? "No followers" : "Not following anyone")
                }
            }
            .padding(24)
        }
        .background(alignment: .top) {
            RouteGradientBackdrop()
        }
        .navigationTitle(title)
        .task(id: artist.permalinkURL) {
            guard let details = try? await model.artistDetails(for: artist),
                  !Task.isCancelled else { return }
            totalUserCount = list == .following ? details.followingsCount : details.followersCount
        }
    }

    private func loadPage() async {
        guard !isLoading, !hasLoaded || nextPageURL != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let pageURL = nextPageURL
            let page = try await model.artistUsers(for: artist, list: list, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || loadedPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURLs = Set(users.map(\.permalinkURL))
            users.append(contentsOf: page.users.filter { knownURLs.insert($0.permalinkURL).inserted })
            if let pageURL { loadedPageURLs.insert(pageURL) }
            nextPageURL = page.nextURL
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
