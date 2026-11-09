#if DEBUG
import ImageIO
import SwiftUI

private struct CacheInspectorGroup: Identifiable, Equatable {
    let name: String
    let sources: [MemoryCacheSnapshot]
    var id: String { name }
}

private struct CacheDiskFile {
    let url: URL
    let modified: Date?
}

private enum CacheValue {
    static func displayKey(_ label: String) -> String {
        // Paging and signed URLs can carry credentials in their query.
        guard label.contains("?"), let url = URL(string: label), url.scheme != nil else { return label }
        return NetworkActivitySanitizer.url(url)
    }

    static func bytes(_ count: Int) -> String {
        Int64(count).formatted(.byteCount(style: .memory))
    }

    private static func count(_ count: Int, _ noun: String, hasMore: Bool = false) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")\(hasMore ? ", more available" : "")"
    }

    // `as? CGImage` succeeds for any value because CGImage is a Core Foundation
    // type, so compare the CF type ID instead.
    private static func cgImage(_ value: Any) -> CGImage? {
        let object = value as AnyObject
        return CFGetTypeID(object) == CGImage.typeID ? (object as! CGImage) : nil
    }

    // Runs for every entry on each poll, so this must not decode anything.
    static func summary(_ value: Any) -> String {
        if let image = cgImage(value) { return "\(image.width)×\(image.height) decoded" }
        return switch value {
        case let data as Data: bytes(data.count)
        case let image as NSImage: "\(Int(image.size.width))×\(Int(image.size.height)) display"
        case let accent as ArtworkAccent:
            String(format: "#%02X%02X%02X", Int(accent.red * 255), Int(accent.green * 255), Int(accent.blue * 255))
        case let track as SoundCloudTrack: "\(track.uploader) – \(track.title)"
        case let playlist as SoundCloudPlaylist: "\(playlist.owner.username) – \(playlist.title)"
        case let details as SoundCloudTrackDetails: "\(details.track.uploader) – \(details.track.title)"
        case let details as SoundCloudArtistDetails: details.user.username
        case let page as SoundCloudTrackPage: count(page.tracks.count, "track", hasMore: page.nextURL != nil)
        case let page as SoundCloudPlaylistPage: count(page.playlists.count, "playlist", hasMore: page.nextURL != nil)
        case let page as SoundCloudUserPage: count(page.users.count, "user", hasMore: page.nextURL != nil)
        case let page as SoundCloudCommentPage: count(page.comments.count, "comment", hasMore: page.nextURL != nil)
        case let profiles as [SoundCloudWebProfile]: count(profiles.count, "profile")
        case let users as [SoundCloudUser]: count(users.count, "user")
        case let waveform as SoundCloudWaveform: count(waveform.samples.count, "sample")
        case let station as SoundCloudStation: "\(station.title ?? "Untitled") – \(count(station.tracks.count, "track"))"
        case let station as RawSystemPlaylist: "\(station.title ?? "Untitled") – \(count(station.tracks.count, "track"))"
        case let contents as PlaylistContents:
            "\(contents.playlist.title) – \(count(contents.tracks.count, "track", hasMore: contents.nextPageURL != nil))"
        case let item as SoundCloudFeedItem:
            "\(item.user.username) \(item.isRepost ? "reposted" : "posted") \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
        case let header as CachedArtistHeader: "\(Int(header.image.size.width))×\(Int(header.image.size.height)) header"
        case let file as CacheDiskFile: file.modified?.formatted(date: .abbreviated, time: .standard) ?? ""
        default:
            Mirror(reflecting: value).children.isEmpty
                ? String(describing: value) : String(describing: type(of: value))
        }
    }

    static func isVisual(_ value: Any) -> Bool {
        value is Data || cgImage(value) != nil || value is NSImage
            || value is ArtworkAccent || value is CachedArtistHeader
    }

    /// Decodes off the main actor so large caches do not stall the app being inspected.
    static func image(_ value: Any, maxPixelSize: Int) async -> NSImage? {
        if let image = cgImage(value) {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        switch value {
        case let image as NSImage: return image
        case let header as CachedArtistHeader: return header.image
        case let data as Data:
            return await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }.value
        default: return nil
        }
    }

    static func tree(_ value: Any) -> String {
        var output = ""
        append(value, label: nil, depth: 0, to: &output)
        return output
    }

    private static func append(_ value: Any, label: String?, depth: Int, to output: inout String) {
        let prefix = String(repeating: "  ", count: depth) + (label.map { "\($0): " } ?? "")
        if let label, ["token", "secret"].contains(where: label.lowercased().contains) {
            output += "\(prefix)[REDACTED]\n"
            return
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let wrapped = mirror.children.first?.value {
                append(wrapped, label: label, depth: depth, to: &output)
            } else {
                output += "\(prefix)nil\n"
            }
            return
        }
        switch value {
        case let url as URL: output += "\(prefix)\(NetworkActivitySanitizer.url(url))\n"
        case let string as String: output += "\(prefix)\(string.debugDescription)\n"
        case let text as AttributedString: output += "\(prefix)\(String(text.characters).debugDescription)\n"
        case let date as Date: output += "\(prefix)\(date.formatted(date: .abbreviated, time: .standard))\n"
        case let data as Data: output += "\(prefix)\(bytes(data.count))\n"
        case let samples as [Int] where samples.count > 16: output += "\(prefix)[\(samples.count) values]\n"
        default:
            guard !mirror.children.isEmpty else {
                output += "\(prefix)\(value)\n"
                return
            }
            let isCollection = mirror.displayStyle == .collection || mirror.displayStyle == .set
                || mirror.displayStyle == .dictionary
            output += prefix + (isCollection ? "[\(mirror.children.count) items]" : String(describing: type(of: value))) + "\n"
            guard depth < 6 else { return }
            for child in mirror.children.prefix(50) {
                append(child.value, label: child.label, depth: depth + 1, to: &output)
            }
            if mirror.children.count > 50 {
                output += String(repeating: "  ", count: depth + 1) + "… \(mirror.children.count - 50) more\n"
            }
        }
    }
}

struct CacheInspectorView: View {
    let model: AppModel

    @State private var groups: [CacheInspectorGroup] = []
    @State private var selectedSourceID: String?
    @State private var selectedEntryID: String?
    @State private var isPaused = false
    @State private var search = ""

    private var selectedSource: MemoryCacheSnapshot? {
        groups.lazy.flatMap(\.sources).first { $0.id == selectedSourceID }
    }

    private var entries: [MemoryCacheSnapshot.Entry] {
        let entries = selectedSource?.entries ?? []
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.label.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSourceID) {
                ForEach(groups) { group in
                    Section(group.name) {
                        ForEach(group.sources) { CacheSourceRow(source: $0) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } content: {
            entriesView
                .navigationSplitViewColumnWidth(min: 380, ideal: 560)
        } detail: {
            detailView
                .navigationSplitViewColumnWidth(min: 280, ideal: 360)
        }
        .searchable(text: $search, prompt: "Filter entries")
        .toolbar {
            Toggle(isPaused ? "Paused" : "Live", isOn: $isPaused)
                .help("Hold the current contents while you look at them")
        }
        .onChange(of: selectedSourceID) { selectedEntryID = nil }
        .frame(minWidth: 960, minHeight: 500)
        .task {
            while !Task.isCancelled {
                if !isPaused { await refresh() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var entriesView: some View {
        if let source = selectedSource {
            if source.entries.isEmpty {
                ContentUnavailableView("Empty", systemImage: "tray", description: Text(source.name))
            } else if source.entries.allSatisfy({ CacheValue.isVisual($0.value) }) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                        ForEach(entries) { entry in
                            CacheVisualCell(entry: entry, isSelected: entry.id == selectedEntryID)
                                .onTapGesture { selectedEntryID = entry.id }
                        }
                    }
                    .padding(12)
                }
            } else {
                Table(entries, selection: $selectedEntryID) {
                    TableColumn("Key", value: \.label)
                    TableColumn("Value", value: \.summary)
                    TableColumn("Size") { Text($0.cost > 0 ? CacheValue.bytes($0.cost) : "–") }.width(70)
                    TableColumn("Hits") { Text($0.hits.map(String.init) ?? "–") }.width(40)
                    TableColumn("Inserted") {
                        Text($0.insertedAt?.formatted(date: .omitted, time: .standard) ?? "–")
                    }.width(80)
                }
                .monospacedDigit()
            }
        } else {
            ContentUnavailableView("Select a cache", systemImage: "internaldrive")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let id = selectedEntryID, let entry = selectedSource?.entries.first(where: { $0.id == id }) {
            CacheEntryDetail(entry: entry)
        } else if selectedEntryID != nil {
            // Polling continues while an entry is selected, so it can disappear.
            ContentUnavailableView("No longer cached", systemImage: "wind")
        } else {
            ContentUnavailableView("Select an entry", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func refresh() async {
        let disk = await Task.detached(priority: .utility) { Self.diskEntries() }.value
        let updated = [
            CacheInspectorGroup(name: "In Memory", sources: MemoryCacheRegistry.shared.snapshots()),
            CacheInspectorGroup(name: "Library", sources: librarySources()),
            CacheInspectorGroup(name: "On Disk", sources: [
                MemoryCacheSnapshot(id: "disk", name: "Application Support", entries: disk)
            ])
        ].map { group in
            CacheInspectorGroup(name: group.name, sources: group.sources.map { source in
                var source = source
                source.entries = source.entries.map { entry in
                    var entry = entry
                    entry.label = CacheValue.displayKey(entry.label)
                    entry.summary = CacheValue.summary(entry.value)
                    return entry
                }
                return source
            })
        }
        if updated != groups { groups = updated }
        if selectedSourceID == nil { selectedSourceID = updated.first?.sources.first?.id }
    }

    // Unbounded state that the controllers keep in memory and mirror to disk.
    private func librarySources() -> [MemoryCacheSnapshot] {
        func source<Item>(
            _ name: String, _ items: [Item], key: (Item) -> String, value: (Item) -> Any = { $0 }
        ) -> MemoryCacheSnapshot {
            var seen = Set<String>()
            return MemoryCacheSnapshot(id: "library-\(name)", name: name, entries: items.compactMap { item in
                let key = key(item)
                guard seen.insert(key).inserted else { return nil }
                return MemoryCacheSnapshot.Entry(id: key, label: key, cost: 0, value: value(item))
            })
        }
        let playlists = model.playlists.cache
        return [
            source("Likes", model.likes.tracks, key: \.urn),
            source("Feed", model.feed.cache.items, key: \.id),
            source("Playlists", playlists.playlists, key: \.urn),
            source("Liked Playlists", playlists.likedPlaylists, key: \.urn),
            source("Playlist Contents", playlists.contents.sorted { $0.key < $1.key }, key: \.key, value: \.value),
            source("History", model.historyTracks, key: \.urn),
            source("Queue", model.queue.tracks, key: \.urn)
        ]
    }

    private nonisolated static func diskEntries() -> [MemoryCacheSnapshot.Entry] {
        let root = URL.applicationSupportDirectory.appending(path: "SoundClaude", directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var entries: [MemoryCacheSnapshot.Entry] = []
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = String(url.path.dropFirst(root.path.count + 1))
            entries.append(MemoryCacheSnapshot.Entry(
                id: path, label: path, cost: values.fileSize ?? 0,
                value: CacheDiskFile(url: url, modified: values.contentModificationDate)
            ))
        }
        return entries.sorted { $0.label < $1.label }
    }
}

private struct CacheSourceRow: View {
    let source: MemoryCacheSnapshot

    private var fill: Double? {
        var fractions: [Double] = []
        if source.countLimit > 0 { fractions.append(Double(source.entries.count) / Double(source.countLimit)) }
        if source.totalCostLimit > 0 { fractions.append(Double(source.totalCost) / Double(source.totalCostLimit)) }
        return fractions.max().map { min($0, 1) }
    }

    private var stats: String {
        var parts: [String] = []
        if source.totalCost > 0 {
            parts.append(CacheValue.bytes(source.totalCost)
                + (source.totalCostLimit > 0 ? " / \(CacheValue.bytes(source.totalCostLimit))" : ""))
        }
        let lookups = source.hits + source.misses
        if lookups > 0 { parts.append("\(source.hits * 100 / lookups)% hit") }
        if source.evictions > 0 { parts.append("\(source.evictions) evicted") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(source.name).lineLimit(1)
                Spacer()
                Text(source.countLimit > 0 ? "\(source.entries.count)/\(source.countLimit)" : "\(source.entries.count)")
                    .foregroundStyle(.secondary)
            }
            if let fill {
                ProgressView(value: fill).controlSize(.mini)
            }
            if !stats.isEmpty {
                Text(stats).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .monospacedDigit()
        .padding(.vertical, 2)
        .tag(source.id)
    }
}

private struct CacheVisualCell: View {
    let entry: MemoryCacheSnapshot.Entry
    let isSelected: Bool

    var body: some View {
        CacheVisualPreview(entryID: entry.id, value: entry.value, maxPixelSize: 176)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .help("\(entry.label)\n\(entry.summary)")
    }
}

private struct CacheVisualPreview: View {
    let entryID: String
    let value: Any
    let maxPixelSize: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let accent = value as? ArtworkAccent {
                Color(red: accent.red, green: accent.green, blue: accent.blue)
            } else if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Color.primary.opacity(0.06)
            }
        }
        // A stable id keeps polling from decoding the same artwork again.
        .task(id: entryID) {
            image = await CacheValue.image(value, maxPixelSize: maxPixelSize)
        }
    }
}

private struct CacheWaveformPreview: View {
    let waveform: SoundCloudWaveform

    var body: some View {
        Canvas { context, size in
            guard !waveform.samples.isEmpty, waveform.height > 0 else { return }
            let columns = max(1, Int(size.width / 2))
            var bars = Path()
            for column in 0..<columns {
                let sample = waveform.samples[column * waveform.samples.count / columns]
                let height = size.height * CGFloat(sample) / CGFloat(waveform.height)
                bars.addRect(CGRect(x: CGFloat(column) * 2, y: size.height - height, width: 1, height: height))
            }
            context.fill(bars, with: .color(.accentColor))
        }
        .frame(height: 64)
    }
}

private struct CacheEntryDetail: View {
    let entry: MemoryCacheSnapshot.Entry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if CacheValue.isVisual(entry.value) {
                    CacheVisualPreview(entryID: entry.id, value: entry.value, maxPixelSize: 640)
                        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 320)
                }
                if let waveform = entry.value as? SoundCloudWaveform {
                    CacheWaveformPreview(waveform: waveform)
                }
                Text(verbatim: entry.label).fontWeight(.semibold)
                Text(verbatim: metadata).foregroundStyle(.secondary)
                if let file = entry.value as? CacheDiskFile {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                }
                Divider()
                Text(verbatim: CacheValue.tree(entry.value))
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private var metadata: String {
        var parts = [entry.summary]
        if entry.cost > 0 { parts.append("Cost \(CacheValue.bytes(entry.cost))") }
        if let hits = entry.hits { parts.append("\(hits) hits") }
        if let inserted = entry.insertedAt { parts.append("Inserted \(inserted.formatted(date: .omitted, time: .standard))") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
#endif
