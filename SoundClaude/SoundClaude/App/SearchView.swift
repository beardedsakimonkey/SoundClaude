import AppKit
import Observation
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

/// The Search page. Its field is in the toolbar, where the results pages share it.
/// `suggestions` fills the page below the recent searches.
struct SearchView<Suggestions: View>: View {
    let user: SoundCloudUser
    let onSearch: (String) -> Void
    @ViewBuilder let suggestions: Suggestions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recentSearches: [String] = []
    @State private var isHoveringClearHistory = false
    private let store = RecentSearchStore()

    var body: some View {
        ScrollbarReservedScrollView { _ in
            searchContent
                .remembersScrollPosition()
        }
        .background(alignment: .top) {
            RouteGradientBackdrop()
        }
        .navigationTitle("Search")
        .onAppear {
            recentSearches = store.restore(for: user)
        }
        #if DEBUG
        .debugViewUpdates("SearchView")
        #endif
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 24) {
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
                            onSearch(query)
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
            suggestions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
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

/// What the search field and its suggestions share. The field sits in the toolbar and
/// the suggestions drop over the page below it, so neither view can own this.
@Observable
final class SearchFieldModel {
    var text = ""
    /// Set to focus the field. The field clears it, so a request focuses only once.
    var focusRequest: UUID?

    fileprivate var isFocused = false
    // Suggest only for text typed during this focus, not for a query restored with the page.
    fileprivate var isSuggesting = false
    fileprivate var suggestions = SoundCloudSearchSuggestions()
    // Only the arrow keys select a suggestion for Return. Hover does not, so a pointer
    // resting under the list cannot replace the typed search.
    fileprivate var selection: Int?
    @ObservationIgnored fileprivate weak var input: NSTextField?
    /// Where the field is in its window, for placing the suggestions under it.
    @ObservationIgnored fileprivate let fieldAnchor = WindowAnchor()

    init(focusRequest: UUID? = nil) {
        self.focusRequest = focusRequest
    }

    fileprivate var visibleSuggestions: SoundCloudSearchSuggestions {
        isFocused && isSuggesting ? suggestions : SoundCloudSearchSuggestions()
    }

    /// Whether the field took focus. It cannot before it is in a window.
    @discardableResult
    fileprivate func focus() -> Bool {
        guard let input, let window = input.window else { return false }
        // Focusing a field that is already being edited would reselect its text.
        return input.currentEditor() != nil || window.makeFirstResponder(input)
    }

    fileprivate func dismissFocus() {
        guard let input, input.currentEditor() != nil else { return }
        input.window?.makeFirstResponder(nil)
    }

    fileprivate func select(_ item: SearchSuggestionItem, actions: SearchFieldActions) {
        switch item {
        case let .query(text):
            let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            self.text = query
            dismissFocus()
            actions.onSearch(query)
        case let .result(result):
            dismissFocus()
            actions.onSelectResult(result)
        }
    }

    fileprivate func submit(actions: SearchFieldActions) {
        let items = visibleSuggestions.items
        let selected = selection.flatMap { items.indices.contains($0) ? items[$0] : nil }
        select(selected ?? .query(text), actions: actions)
    }

    fileprivate func moveSelection(by delta: Int) -> Bool {
        let count = visibleSuggestions.items.count
        guard count > 0 else { return false }
        // Stepping past either end returns to the typed text.
        let next = (selection ?? (delta > 0 ? -1 : count)) + delta
        selection = (0..<count).contains(next) ? next : nil
        return true
    }

    /// Escape closes the suggestions first, then gives up focus.
    fileprivate func exit() {
        if !visibleSuggestions.isEmpty {
            isSuggesting = false
            return
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = "" }
        dismissFocus()
    }
}

struct SearchFieldActions {
    let onSearch: (String) -> Void
    /// Opens a top result picked from the suggestions.
    var onSelectResult: (SoundCloudSearchResult) -> Void = { _ in }
}

/// The search field for the toolbar. `SearchSuggestionDropdown` shows its suggestions.
struct SearchField: View {
    let model: SearchFieldModel
    /// Completions and top results for the text typed so far.
    var suggest: (String) async -> SoundCloudSearchSuggestions = { _ in SoundCloudSearchSuggestions() }
    let actions: SearchFieldActions

    @State private var isHoveringClear = false

    private static let debounce: Duration = .milliseconds(150)

    private var query: String {
        model.isSuggesting ? model.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            SearchFieldInput(model: model, text: model.text, actions: actions)
            if !model.text.isEmpty {
                Button {
                    model.text = ""
                    model.focus()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(isHoveringClear ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .onContentHover { isHoveringClear = $0 }
                .accessibilityLabel("Clear search")
                .contentHelp("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            // The toolbar gives its items a glass background from macOS 26.
            if #unavailable(macOS 26.0) {
                RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.focus() })
        .background { SearchOutsideClickView(isFocused: model.isFocused) }
        .background { WindowAnchorView(anchor: model.fieldAnchor) }
        .task(id: model.focusRequest) {
            guard model.focusRequest != nil else { return }
            // The toolbar puts a new field in the window a little after it is made.
            for _ in 0..<40 where !model.focus() {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled else { return }
            }
            // Going Back to a page with the field must not focus it again.
            model.focusRequest = nil
        }
        .task(id: query) {
            let query = query
            guard !query.isEmpty else {
                model.suggestions = SoundCloudSearchSuggestions()
                model.selection = nil
                return
            }
            // Keep the previous suggestions up while typing so the list does not flicker.
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let result = await suggest(query)
            guard !Task.isCancelled else { return }
            model.suggestions = result
            model.selection = nil
        }
        .onDisappear {
            model.isFocused = false
            model.isSuggesting = false
        }
    }
}

// SwiftUI's focus state does not reach a text field in a toolbar item: it neither
// focuses the field nor hears of its focus. So the field is AppKit's, which does both.
private struct SearchFieldInput: NSViewRepresentable {
    let model: SearchFieldModel
    let text: String
    let actions: SearchFieldActions

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, actions: actions)
    }

    func makeNSView(context: Context) -> InputField {
        let field = InputField()
        field.delegate = context.coordinator
        field.onFocusChange = { [model] isFocused in
            model.isFocused = isFocused
            if !isFocused { model.isSuggesting = false }
        }
        field.placeholderString = "Search tracks, users, and playlists"
        field.setAccessibilityLabel("Search SoundCloud")
        field.isBordered = false
        field.drawsBackground = false
        // AppKit draws the focus ring, around the whole field rather than just the text.
        field.focusRingType = .exterior
        field.focusRingAnchor = model.fieldAnchor
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        // Fill the width on offer rather than fit the text.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = text
        // SwiftUI can make fields it never shows. Only the one in the window counts.
        field.onMoveToWindow = { [model, weak field] in model.input = field }
        return field
    }

    func updateNSView(_ field: InputField, context: Context) {
        context.coordinator.actions = actions
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: SearchFieldModel
        var actions: SearchFieldActions

        init(model: SearchFieldModel, actions: SearchFieldActions) {
            self.model = model
            self.actions = actions
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.text = field.stringValue
            model.isSuggesting = true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                return model.moveSelection(by: 1)
            case #selector(NSResponder.moveUp(_:)):
                return model.moveSelection(by: -1)
            case #selector(NSResponder.insertNewline(_:)):
                model.submit(actions: actions)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                model.exit()
                return true
            default:
                return false
            }
        }
    }

    final class InputField: NSTextField {
        var onFocusChange: ((Bool) -> Void)?
        var onMoveToWindow: (() -> Void)?
        var focusRingAnchor: WindowAnchor?
        // Keep the field out of macOS's initial focus selection.
        private var isReady = false

        override var acceptsFirstResponder: Bool { isReady && super.acceptsFirstResponder }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            isReady = false
            guard window != nil else { return }
            onMoveToWindow?()
            DispatchQueue.main.async { [weak self] in self?.isReady = true }
        }

        /// The whole field, icon and padding included, in this view's coordinates.
        private var focusRingRect: NSRect {
            guard let view = focusRingAnchor?.view, view.window === window else { return bounds }
            return convert(view.bounds, from: view)
        }

        override var focusRingMaskBounds: NSRect { focusRingRect }

        override func drawFocusRingMask() {
            let rect = focusRingRect
            // The toolbar's glass is a capsule from macOS 26.
            let radius: CGFloat = if #available(macOS 26.0, *) { rect.height / 2 } else { 8 }
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocusChange?(true) }
            return became
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            onFocusChange?(false)
        }
    }
}

/// The search field's suggestions. Overlay this on the page under the toolbar: a
/// toolbar item cannot draw or take clicks outside its own bounds.
struct SearchSuggestionDropdown: View {
    let model: SearchFieldModel
    let artworkLoader: ArtworkLoader
    /// Space at the bottom of the page that the list must stay clear of.
    var bottomInset: CGFloat = 0
    let actions: SearchFieldActions

    @State private var pageAnchor = WindowAnchor()

    /// Space between the top of the page and the list.
    static let gap: CGFloat = 4
    private static let width: CGFloat = 400
    private static let margin: CGFloat = 12

    var body: some View {
        let visible = model.visibleSuggestions
        ZStack(alignment: .topLeading) {
            WindowAnchorView(anchor: pageAnchor)
                .allowsHitTesting(false)
            if !visible.isEmpty {
                // Measured when the list opens. The field does not move while it has focus.
                let page = pageAnchor.frame ?? .zero
                let width = min(Self.width, max(0, page.width - 2 * Self.margin))
                let fieldMidX = model.fieldAnchor.frame?.midX ?? page.midX
                let x = min(max(fieldMidX - width / 2 - page.minX, Self.margin), page.width - Self.margin - width)
                let limit = max(120, page.height - bottomInset - Self.gap - Self.margin)
                SearchSuggestionList(
                    suggestions: visible, typed: model.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    selection: model.selection, artworkLoader: artworkLoader,
                    onSelect: { model.select($0, actions: actions) }
                )
                .frame(width: width, height: SearchSuggestionList.height(for: visible, limit: limit))
                .background { SearchDropdownRegion().allowsHitTesting(false) }
                .padding(.top, Self.gap)
                .offset(x: x)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// An AppKit view's frame in its window, read on demand.
private final class WindowAnchor {
    weak var view: NSView?

    var frame: CGRect? {
        guard let view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }
}

private struct WindowAnchorView: NSViewRepresentable {
    let anchor: WindowAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        view.anchor = anchor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PassthroughView: NSView {
        var anchor: WindowAnchor?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // SwiftUI can make views it never shows. Only the one in the window counts.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { anchor?.view = self }
        }
    }
}

/// Completions of the query, then its top results, in one keyboard-navigable list.
private struct SearchSuggestionList: View {
    static let queryRowHeight: CGFloat = 30
    static let resultRowHeight: CGFloat = 54
    static let padding: CGFloat = 6

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
                artworkURL: result.artworkURL,
                loader: artworkLoader,
                size: Self.artworkSize,
                shape: RoundedRectangle(cornerRadius: result.isUser ? Self.artworkSize / 2 : 4)
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
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
