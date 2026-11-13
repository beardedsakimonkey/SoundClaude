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

struct SearchView: View {
    let user: SoundCloudUser
    @Binding var searchText: String
    let focusRequest: UUID?
    let artworkLoader: ArtworkLoader
    /// Completions and top results for the text typed so far.
    var suggestions: (String) async -> SoundCloudSearchSuggestions = { _ in SoundCloudSearchSuggestions() }
    let onSearch: (String) -> Void
    /// Opens a top result picked from the suggestions.
    var onSelectResult: (SoundCloudSearchResult) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recentSearches: [String] = []
    @State private var isHoveringClearHistory = false
    @State private var dismissFocusRequest = UUID()
    private let store = RecentSearchStore()

    var body: some View {
        ScrollbarReservedScrollView { contentSize in
            searchContent
                .environment(\.searchViewportHeight, contentSize.height)
                .remembersScrollPosition()
        }
        .background(alignment: .top) {
            RouteGradientBackdrop()
        }
        .navigationTitle("Search")
        .task(id: focusRequest) {
            recentSearches = store.restore(for: user)
        }
        #if DEBUG
        .debugViewUpdates("SearchView")
        #endif
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Search")
                .font(.largeTitle.weight(.semibold))

            SearchInputView(
                text: $searchText,
                focusRequest: focusRequest,
                dismissFocusRequest: dismissFocusRequest,
                artworkLoader: artworkLoader,
                suggest: suggestions,
                onSelect: select
            )
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity, alignment: .center)
            // Suggestions drop down over the recent searches.
            .zIndex(1)

            if !recentSearches.isEmpty {
                HStack {
                    Text("Recent")
                        .font(.sectionHeading)
                    Spacer()
                    Button {
                        store.clear(for: user)
                        recentSearches = []
                    } label: {
                        Text("Clear")
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

    private func select(_ item: SearchSuggestionItem) {
        switch item {
        case let .query(query):
            search(query)
        case let .result(result):
            dismissFocusRequest = UUID()
            onSelectResult(result)
        }
    }

    private func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchText = query
        recentSearches = store.record(query, for: user)
        dismissFocusRequest = UUID()
        onSearch(query)
    }
}

private enum SearchSuggestionItem {
    case query(String)
    case result(SoundCloudSearchResult)
}

private extension SoundCloudSearchSuggestions {
    var items: [SearchSuggestionItem] {
        queries.map(SearchSuggestionItem.query) + results.map(SearchSuggestionItem.result)
    }
}

// Keep focus changes local so they do not update the recent searches or backdrop.
private struct SearchInputView: View {
    @Binding var text: String
    let focusRequest: UUID?
    let dismissFocusRequest: UUID
    let artworkLoader: ArtworkLoader
    let suggest: (String) async -> SoundCloudSearchSuggestions
    let onSelect: (SearchSuggestionItem) -> Void

    @Environment(\.searchViewportHeight) private var viewportHeight
    @FocusState private var isFocused: Bool
    @State private var suggestions = SoundCloudSearchSuggestions()
    // Only the arrow keys select a suggestion for Return. Hover does not, so a pointer
    // resting under the list cannot replace the typed search.
    @State private var selection: Int?
    // Suggest only for text typed during this focus, not for a query restored with the page.
    @State private var isSuggesting = false

    private static let debounce: Duration = .milliseconds(150)
    /// Roughly where the list starts on the page, plus a margin below it.
    private static let viewportReserve: CGFloat = 150

    private var query: String {
        isSuggesting ? text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private var visibleSuggestions: SoundCloudSearchSuggestions {
        isFocused && isSuggesting ? suggestions : SoundCloudSearchSuggestions()
    }

    var body: some View {
        let visible = visibleSuggestions
        let listHeight = SearchSuggestionList.height(
            for: visible, limit: max(120, viewportHeight - Self.viewportReserve)
        )
        let dropdownHeight = visible.isEmpty ? 0 : SearchSuggestionList.gap + listHeight
        SearchTextField(
            placeholder: "Search tracks, users, and playlists",
            text: $text,
            isFocused: $isFocused,
            accessibilityLabel: "Search SoundCloud",
            preventsAutomaticFocus: true,
            dropdownHeight: dropdownHeight,
            // The text field keeps the first handlers it is given, so they read state
            // when called rather than capturing this pass's suggestions.
            onSubmit: {
                let items = visibleSuggestions.items
                onSelect(selection.flatMap { items.indices.contains($0) ? items[$0] : nil } ?? .query(text))
            },
            onClear: { isFocused = true },
            onExit: {
                guard !visibleSuggestions.isEmpty else { return false }
                isSuggesting = false
                return true
            }
        )
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        // An overlay only takes clicks within the bounds of the view it is on, so grow
        // those over the list, then give the space back so the page does not move.
        .padding(.bottom, dropdownHeight)
        .overlay(alignment: .bottom) {
            if !visible.isEmpty {
                SearchSuggestionList(
                    suggestions: visible, typed: query, selection: selection,
                    artworkLoader: artworkLoader, onSelect: onSelect
                )
                .frame(height: listHeight)
            }
        }
        .padding(.bottom, -dropdownHeight)
        .task(id: focusRequest) {
            guard focusRequest != nil else { return }
            // Wait until the navigation stack has mounted the text field.
            await Task.yield()
            guard !Task.isCancelled else { return }
            isFocused = true
        }
        .onChange(of: dismissFocusRequest) { _, _ in
            isFocused = false
        }
        .onChange(of: text) { _, _ in
            if isFocused { isSuggesting = true }
        }
        .onChange(of: isFocused) { _, isFocused in
            if !isFocused { isSuggesting = false }
        }
        .task(id: query) {
            let query = query
            guard !query.isEmpty else {
                suggestions = SoundCloudSearchSuggestions()
                selection = nil
                return
            }
            // Keep the previous suggestions up while typing so the list does not flicker.
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let result = await suggest(query)
            guard !Task.isCancelled else { return }
            suggestions = result
            selection = nil
        }
        .onDisappear { isFocused = false }
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        let count = visibleSuggestions.items.count
        guard count > 0 else { return .ignored }
        // Stepping past either end returns to the typed text.
        let next = (selection ?? (delta > 0 ? -1 : count)) + delta
        selection = (0..<count).contains(next) ? next : nil
        return .handled
    }
}

/// Completions of the query, then its top results, in one keyboard-navigable list.
private struct SearchSuggestionList: View {
    static let queryRowHeight: CGFloat = 30
    static let resultRowHeight: CGFloat = 54
    static let padding: CGFloat = 6
    /// Space between the field and the list.
    static let gap: CGFloat = 6

    /// Tall enough for every row, up to `limit`; past that the list scrolls.
    static func height(for suggestions: SoundCloudSearchSuggestions, limit: CGFloat) -> CGFloat {
        let rows = CGFloat(suggestions.queries.count) * queryRowHeight
            + CGFloat(suggestions.results.count) * resultRowHeight
        return min(2 * padding + rows, limit)
    }

    let suggestions: SoundCloudSearchSuggestions
    let typed: String
    let selection: Int?
    let artworkLoader: ArtworkLoader
    let onSelect: (SearchSuggestionItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.items.enumerated()), id: \.offset) { index, item in
                        SearchSuggestionRow(isSelected: index == selection) {
                            onSelect(item)
                        } label: {
                            switch item {
                            case let .query(query):
                                SearchQueryLabel(query: query, typed: typed)
                            case let .result(result):
                                SearchResultLabel(
                                    result: result, artworkLoader: artworkLoader,
                                    // Results are ruled off from the completions and from each other.
                                    showsDivider: index > 0
                                )
                            }
                        }
                        .id(index)
                    }
                }
                .padding(Self.padding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: selection) { _, selection in
                if let selection { proxy.scrollTo(selection) }
            }
        }
        .modifier(SearchSuggestionPanel())
    }
}

private struct SearchSuggestionPanel: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let rows = content.clipShape(shape)
        if #available(macOS 26.0, *) {
            // Glass applied to the content itself would take the rows' clicks.
            rows.background { Color.clear.glassEffect(.regular, in: shape) }
        } else {
            rows.background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        }
    }
}

private struct SearchSuggestionRow<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(isSelected || isHovering ? 0.1 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContentHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SearchQueryLabel: View {
    let query: String
    let typed: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            text
                .lineLimit(1)
        }
        .frame(height: SearchSuggestionList.queryRowHeight)
    }

    // Pick out what was typed, wherever the completion has it.
    private var text: Text {
        guard let match = query.range(of: typed, options: .caseInsensitive) else {
            return Text(query).foregroundStyle(.secondary)
        }
        let before = Text(query[..<match.lowerBound]).foregroundStyle(.secondary)
        let matched = Text(query[match]).foregroundStyle(.primary).fontWeight(.semibold)
        let after = Text(query[match.upperBound...]).foregroundStyle(.secondary)
        return Text("\(before)\(matched)\(after)")
    }
}

private struct SearchResultLabel: View {
    static let artworkSize: CGFloat = 42

    let result: SoundCloudSearchResult
    let artworkLoader: ArtworkLoader
    let showsDivider: Bool

    var body: some View {
        HStack(spacing: 10) {
            TrackArtworkView(
                artworkURL: artworkURL,
                loader: artworkLoader,
                size: Self.artworkSize,
                shape: RoundedRectangle(cornerRadius: isUser ? Self.artworkSize / 2 : 4)
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .frame(height: SearchSuggestionList.resultRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            // A system divider all but vanishes on the panel's material.
            if showsDivider { Rectangle().fill(.primary.opacity(0.12)).frame(height: 1) }
        }
    }

    private var isUser: Bool {
        if case .user = result { true } else { false }
    }

    private var artworkURL: URL? {
        switch result {
        case let .user(user): user.avatarURL
        case let .track(track): track.displayArtworkURL
        case let .playlist(playlist): playlist.artworkURL ?? playlist.owner.avatarURL
        }
    }

    private var title: String {
        switch result {
        case let .user(user): user.username
        case let .track(track): track.title
        case let .playlist(playlist): playlist.title
        }
    }

    private var subtitle: String {
        switch result {
        case .user: "Artist"
        case let .track(track): "Track · \(track.uploader)"
        case let .playlist(playlist): "Playlist · \(playlist.owner.username)"
        }
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(RecentSearchButtonStyle())
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
                    .allowsHitTesting(false)
            }
            .contentHelp("Search again: \(query)")
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
            .contentHelp("Remove recent search: \(query)")
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

private struct RecentSearchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
            }
    }
}
