import SwiftUI

struct SearchView: View {
    let user: SoundCloudUser
    @Binding var searchText: String
    let focusRequest: UUID
    let onSearch: (String) -> Void

    @State private var recentSearches: [String] = []
    @FocusState private var isSearchFocused: Bool
    private let store = RecentSearchStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search SoundCloud", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { search(searchText) }
                    .onExitCommand { isSearchFocused = false }
                    .accessibilityLabel("Search SoundCloud")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
                Button("Search") { search(searchText) }
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .background {
                SearchOutsideClickView(isFocused: isSearchFocused) {
                    isSearchFocused = false
                }
            }

            if !recentSearches.isEmpty {
                HStack {
                    Text("Recent searches")
                        .font(.headline)
                    Spacer()
                    Button("Clear history") {
                        store.clear(for: user)
                        recentSearches = []
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 12) {
                        ForEach(recentSearches, id: \.self) { query in
                            Button { search(query) } label: {
                                Label(query, systemImage: "clock.arrow.circlepath")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .buttonStyle(.bordered)
                            .help("Search again: \(query)")
                            .accessibilityLabel("Search again: \(query)")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .navigationTitle("Search")
        .task(id: focusRequest) {
            recentSearches = store.restore(for: user)
            // Wait until the navigation stack has mounted the text field.
            await Task.yield()
            guard !Task.isCancelled else { return }
            isSearchFocused = true
        }
        .onDisappear { isSearchFocused = false }
    }

    private func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchText = query
        recentSearches = store.record(query, for: user)
        isSearchFocused = false
        onSearch(query)
    }
}
