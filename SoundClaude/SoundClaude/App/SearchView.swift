import SwiftUI

private struct SearchViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var searchViewportHeight: CGFloat {
        get { self[SearchViewportHeightKey.self] }
        set { self[SearchViewportHeightKey.self] = newValue }
    }
}

struct SearchView<Results: View>: View {
    let user: SoundCloudUser
    @Binding var searchText: String
    let focusRequest: UUID
    @ViewBuilder let results: (String) -> Results

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var submittedQuery: String?
    @State private var recentSearches: [String] = []
    @State private var isHoveringClearHistory = false
    @FocusState private var isSearchFocused: Bool
    private let store = RecentSearchStore()

    var body: some View {
        GeometryReader { geometry in
            searchScrollView
                .environment(\.searchViewportHeight, geometry.size.height)
        }
        .background(alignment: .top) {
            RouteGradientBackdrop()
        }
        .navigationTitle("Search")
        .task(id: focusRequest) {
            recentSearches = store.restore(for: user)
            // Wait until the navigation stack has mounted the text field.
            await Task.yield()
            guard !Task.isCancelled else { return }
            isSearchFocused = true
        }
        .onChange(of: searchText) { _, text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                submittedQuery = nil
            }
        }
        .onDisappear { isSearchFocused = false }
    }

    private var searchScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Search")
                    .font(.largeTitle.weight(.semibold))

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search tracks, users, and playlists", text: $searchText)
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
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    Button("Search") { search(searchText) }
                        .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: searchText.isEmpty)
                .padding(12)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .background {
                    SearchOutsideClickView(isFocused: isSearchFocused) {
                        isSearchFocused = false
                    }
                }
                .frame(maxWidth: 450)
                .frame(maxWidth: .infinity, alignment: .center)

                if let submittedQuery {
                    results(submittedQuery)
                        .id(submittedQuery)
                } else if !recentSearches.isEmpty {
                    HStack {
                        Text("Recent")
                            .font(.headline)
                        Spacer()
                        Button {
                            store.clear(for: user)
                            recentSearches = []
                        } label: {
                            Text("Clear history")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isHoveringClearHistory ? Color.primary : Color.secondary)
                        .onContentHover { isHoveringClearHistory = $0 }
                    }
                    .transition(.identity)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 12) {
                        ForEach(recentSearches, id: \.self) { query in
                            RecentSearchButton(query: query) {
                                search(query)
                            } onRemove: {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                    recentSearches = store.remove(query, for: user)
                                }
                            }
                            .transition(.identity)
                        }
                    }
                    .transition(.identity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchText = query
        recentSearches = store.record(query, for: user)
        isSearchFocused = false
        submittedQuery = query
    }
}

private struct RecentSearchButton: View {
    let query: String
    let onSearch: () -> Void
    let onRemove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isHoveringRemove = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSearch) {
                Label(query, systemImage: "clock.arrow.circlepath")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                            if isHovering {
                                LinearGradient(
                                    colors: [.black, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 24)
                                Color.clear.frame(width: 24)
                            }
                        }
                    }
                    .padding(8)
            }
            .buttonStyle(.bordered)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
                    .allowsHitTesting(false)
            }
            .help("Search again: \(query)")
            .accessibilityLabel("Search again: \(query)")
            .accessibilityAction(named: Text("Remove recent search"), onRemove)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHoveringRemove ? Color.red : Color.secondary)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHoveringRemove)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove recent search: \(query)")
            .accessibilityLabel("Remove recent search: \(query)")
            .onContentHover { isHoveringRemove = $0 }
            .opacity(isHovering ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)
            .padding(.trailing, 8)
        }
        .onContentHover { isHovering = $0 }
    }
}
