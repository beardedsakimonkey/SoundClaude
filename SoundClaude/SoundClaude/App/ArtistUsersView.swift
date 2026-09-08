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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text(artist.username)
                    .font(.title2)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 24)], spacing: 24) {
                    ForEach(users, id: \.permalinkURL) { user in
                        Button {
                            onSelectArtist(user)
                        } label: {
                            VStack(spacing: 10) {
                                TrackArtworkView(
                                    artworkURL: user.avatarURL,
                                    loader: model.artworkLoader,
                                    size: 120,
                                    rendition: .square500
                                )
                                .clipShape(Circle())
                                Text(user.username)
                                    .font(.headline)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(height: 40, alignment: .top)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("View profile: \(user.username)")
                        .accessibilityLabel("View profile: \(user.username)")
                    }
                }

                if let errorMessage {
                    VStack(spacing: 8) {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await loadPage() } }
                            .disabled(isLoading)
                    }
                    .frame(maxWidth: .infinity)
                } else if !hasLoaded || nextPageURL != nil {
                    ProgressView("Loading \(list.title.lowercased())")
                        .frame(maxWidth: .infinity)
                        .task(id: nextPageURL) { await loadPage() }
                } else if users.isEmpty {
                    ContentUnavailableView(
                        list == .followers ? "No followers" : "Not following anyone",
                        systemImage: "person.2",
                        description: Text(list == .followers
                            ? "This artist has no followers yet."
                            : "This artist is not following anyone yet.")
                    )
                }
            }
            .padding(24)
        }
        .navigationTitle(list.title)
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
