import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Recently Added", title = "Title", lastPlayed = "Last Played"
    var id: String { rawValue }
}

enum LibraryRoute: Identifiable {
    case detail(MediaItem)
    case series(Series)

    var id: String {
        switch self {
        case .detail(let item): return "detail-" + item.id.uuidString
        case .series(let show): return "series-" + show.id
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImporter = false
    @State private var showFolderPicker = false
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var sort: LibrarySort = .recent

    @State private var playing: MediaItem?
    @State private var route: LibraryRoute?

    @State private var renaming: MediaItem?
    @State private var renameText = ""

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .audio, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg, .mpeg2Video]
        for ext in ["mkv", "webm", "ts", "m2ts", "flv", "wmv", "srt", "vtt", "flac", "ogg", "opus"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    var body: some View {
        NavigationStack {
            Group { if store.items.isEmpty { emptyState } else { libraryList } }
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationTitle("Mina Anii")
            .searchable(text: $searchText, prompt: "Search your library")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    sortMenu
                    Menu {
                        Button { showImporter = true } label: { Label("Import Files", systemImage: "doc.badge.plus") }
                        Button { showFolderPicker = true } label: { Label("Add Media Source", systemImage: "folder.badge.plus") }
                    } label: { Image(systemName: "plus") }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            // Attached inside the NavigationStack, deliberately. Two fileImporters
            // on the same view cancel each other out; on different views both work.
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { Task { await store.addFolder(url) } }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { Task { await store.importFiles(urls) } }
        }
        .fullScreenCover(item: $playing) { item in PlayerScreen(item: item, store: store) }
        .sheet(item: $route) { destination in
            switch destination {
            case .detail(let item):
                MediaDetailView(item: item, playingItem: $playing)
            case .series(let show):
                SeriesDetailView(series: show, playingItem: $playing).environmentObject(store)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { if let item = renaming { store.rename(item, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .task { await store.rescan() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.rescan() } }
        }
    }

    // MARK: - Sections

    private var libraryList: some View {
        // Grouped once per redraw and handed down, rather than rebuilt by every
        // computed property that happens to need it.
        let grouped = store.items.groupedIntoEntries()
        let upNext = searchText.isEmpty ? Self.continueWatching(in: grouped) : []

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !upNext.isEmpty {
                    sectionHeader("Continue Watching")
                    continueRow(upNext)
                }
                sectionHeader(searchText.isEmpty ? "Library" : "Results")
                grid(grouped)
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.title3.weight(.semibold)).foregroundStyle(.white)
    }

    private func continueRow(_ items: [MediaItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    Button { route = .detail(item) } label: {
                        ContinueCard(item: item, thumbURL: store.thumbURL(for: item))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextButtons(for: item) }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func grid(_ grouped: [LibraryEntry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 16)],
                  alignment: .leading, spacing: 20) {
            if searchText.isEmpty {
                ForEach(sorted(grouped)) { entry in
                    switch entry {
                    case .movie(let item):
                        Button { route = .detail(item) } label: {
                            MediaCard(item: item, thumbURL: store.thumbURL(for: item))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextButtons(for: item) }

                    case .series(let show):
                        Button { route = .series(show) } label: {
                            SeriesCard(series: show)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { seriesButtons(for: show) }
                    }
                }
            } else {
                ForEach(searchResults) { item in
                    Button { route = .detail(item) } label: {
                        MediaCard(item: item, thumbURL: store.thumbURL(for: item))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextButtons(for: item) }
                }
            }
        }
    }

    // MARK: - Menus

    @ViewBuilder
    private func contextButtons(for item: MediaItem) -> some View {
        Button { playing = item } label: { Label("Play", systemImage: "play.fill") }
        Button { store.resetProgress(item); playing = item } label: { Label("Play from Beginning", systemImage: "gobackward") }
        Button { renameText = item.title; renaming = item } label: { Label("Rename", systemImage: "pencil") }
        if item.isWatched {
            Button { store.resetProgress(item) } label: { Label("Mark as Unwatched", systemImage: "eye.slash") }
        } else if item.duration > 0 {
            Button { store.markWatched(item) } label: { Label("Mark as Watched", systemImage: "eye") }
        }
        Button(role: .destructive) { store.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder
    private func seriesButtons(for show: Series) -> some View {
        if let next = show.nextUp {
            Button { playing = next } label: {
                Label("Play \(next.episodeCode)", systemImage: "play.fill")
            }
        }
        Button { route = .series(show) } label: { Label("Show Episodes", systemImage: "list.bullet") }
        Button { for episode in show.episodes { store.markWatched(episode) } } label: {
            Label("Mark Series as Watched", systemImage: "eye")
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) { ForEach(LibrarySort.allCases) { s in Text(s.rawValue).tag(s) } }
        } label: { Image(systemName: "arrow.up.arrow.down") }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack").font(.system(size: 64)).foregroundStyle(.purple)
            Text("Your library is empty").font(.title2.weight(.semibold))
            Text("Import videos with the + button, share files to Mina Anii from any app, or drop them into On My iPad › Mina Anii using the Files app.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { showImporter = true } label: {
                Label("Import Media", systemImage: "plus").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    /// A movie you left half-finished, and for every show you have started,
    /// either the episode you paused or the next one you have not seen.
    ///
    /// A never-started show stays out. A finished show stays out. An episode
    /// that has never been played carries no lastPlayed date of its own, so it
    /// sorts by when you last watched anything from that show.
    private static func continueWatching(in grouped: [LibraryEntry]) -> [MediaItem] {
        var candidates: [(item: MediaItem, watchedAt: Date)] = []

        for entry in grouped {
            switch entry {
            case .movie(let item):
                guard item.lastPosition > 20, item.duration > 0, !item.isWatched else { continue }
                candidates.append((item, item.lastPlayed ?? item.dateAdded))

            case .series(let show):
                guard let episode = show.continueEpisode else { continue }
                candidates.append((episode, episode.lastPlayed ?? show.lastPlayed ?? episode.dateAdded))
            }
        }

        return candidates.sorted { $0.watchedAt > $1.watchedAt }.map(\.item)
    }

    private func sorted(_ grouped: [LibraryEntry]) -> [LibraryEntry] {
        var result = grouped
        switch sort {
        case .recent:
            result.sort { $0.dateAdded > $1.dateAdded }
        case .title:
            result.sort { $0.sortTitle.localizedCaseInsensitiveCompare($1.sortTitle) == .orderedAscending }
        case .lastPlayed:
            result.sort { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
        return result
    }

    private var searchResults: [MediaItem] {
        store.items
            .filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.fileName.localizedCaseInsensitiveContains(searchText) ||
                ($0.metadata?.title ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.dateAdded > $1.dateAdded }
    }
}

// MARK: - Series card

struct SeriesCard: View {
    let series: Series

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(SeriesPoster(posterURL: series.posterURL))
                .overlay(alignment: .topTrailing) { countBadge }
                .overlay(alignment: .bottomLeading) { unwatchedBadge }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)

            Text(series.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)

            Text(series.subtitle)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }

    private var countBadge: some View {
        Label("\(series.episodeCount)", systemImage: "square.stack.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.65), in: Capsule())
            .padding(6)
    }

    @ViewBuilder
    private var unwatchedBadge: some View {
        if series.unwatchedCount > 0 && series.unwatchedCount < series.episodeCount {
            Text("\(series.unwatchedCount) new")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.purple, in: Capsule())
                .padding(6)
        }
    }
}

/// A show has no local frame grab of its own, so this is poster or nothing.
struct SeriesPoster: View {
    let posterURL: URL?

    var body: some View {
        ZStack {
            Rectangle().fill(
                LinearGradient(colors: [Color(white: 0.18), Color(white: 0.10)],
                               startPoint: .top, endPoint: .bottom)
            )
            if let posterURL {
                AsyncImage(url: posterURL, transaction: Transaction(animation: .easeIn(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .empty: ProgressView().tint(.white.opacity(0.5))
                    default: Image(systemName: "tv").font(.system(size: 30)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "tv").font(.system(size: 30)).foregroundStyle(.secondary)
            }
        }
        .clipped()
    }
}

// MARK: - Portrait card (single file: movie, or episode inside search results)

struct MediaCard: View {
    let item: MediaItem
    let thumbURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
            Text(item.metadata?.title ?? item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
            Text(caption)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }

    private var artwork: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay(
                ArtworkImage(thumbURL: thumbURL,
                             remoteURL: item.metadata?.posterURL,
                             isAudio: item.isAudio)
            )
            .overlay(alignment: .bottom) { progressBar }
            .overlay(alignment: .topTrailing) { durationPill }
            .overlay(alignment: .topLeading) { formatPill }
            .overlay(alignment: .bottomTrailing) { watchedBadge }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
    }

    @ViewBuilder
    private var progressBar: some View {
        if item.progress > 0.01 && !item.isWatched {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.45))
                    Rectangle().fill(Color.purple).frame(width: geo.size.width * item.progress)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    @ViewBuilder
    private var durationPill: some View {
        if item.duration > 0 {
            Text(formatTime(item.duration))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.65), in: Capsule())
                .padding(6)
        }
    }

    @ViewBuilder
    private var formatPill: some View {
        if !item.isEngineSupported {
            Text(item.fileExtension.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.orange.opacity(0.9), in: Capsule())
                .padding(6)
        }
    }

    @ViewBuilder
    private var watchedBadge: some View {
        if item.isWatched {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white, .purple)
                .padding(7)
        }
    }

    private var caption: String {
        var parts: [String] = []
        if item.isEpisode, item.episodeNumber > 0 {
            parts.append(item.episodeCode)
        } else if let year = item.metadata?.releaseYear, !year.isEmpty {
            parts.append(year)
        }
        if item.isWatched {
            parts.append("Watched")
        } else if item.progress > 0.01, item.duration > 0 {
            parts.append("\(formatTime(max(item.duration - item.lastPosition, 0))) left")
        } else if parts.isEmpty {
            parts.append(item.fileExtension.uppercased())
        }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Continue Watching card (landscape, uses the backdrop)

struct ContinueCard: View {
    let item: MediaItem
    let thumbURL: URL

    private let cardWidth: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(width: cardWidth, height: cardWidth * 9 / 16)
                    .overlay(
                        ArtworkImage(thumbURL: thumbURL,
                                     remoteURL: item.metadata?.backdropURL,
                                     isAudio: item.isAudio)
                    )
                    .overlay(Color.black.opacity(0.15))
                    .overlay(
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.white.opacity(0.92))
                    )

                if item.progress > 0.01 {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25))
                        Rectangle().fill(Color.purple).frame(width: cardWidth * item.progress)
                    }
                    .frame(height: 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(item.metadata?.title ?? item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(width: cardWidth)
    }

    private var subtitle: String {
        guard item.progress > 0.01 else {
            return item.isEpisode && item.episodeNumber > 0 ? "Up Next • \(item.episodeCode)" : "Up Next"
        }
        let left = "\(formatTime(max(item.duration - item.lastPosition, 0))) left"
        if item.isEpisode, item.episodeNumber > 0 { return "\(item.episodeCode) • \(left)" }
        return left
    }
}

// MARK: - Artwork loader

/// Draws a remote TMDB image when one exists, otherwise the locally
/// generated frame grab. A landscape frame grab placed in a portrait
/// frame is shown whole over a blurred copy of itself rather than cropped.
struct ArtworkImage: View {
    let thumbURL: URL
    var remoteURL: URL? = nil
    var isAudio: Bool = false

    @State private var local: UIImage?
    @State private var remoteFailed = false

    private var usingRemote: Bool { remoteURL != nil && !remoteFailed }

    var body: some View {
        ZStack {
            Rectangle().fill(
                LinearGradient(colors: [Color(white: 0.18), Color(white: 0.10)],
                               startPoint: .top, endPoint: .bottom)
            )

            if usingRemote, let remoteURL {
                AsyncImage(url: remoteURL, transaction: Transaction(animation: .easeIn(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color.clear.onAppear { remoteFailed = true }
                    case .empty:
                        ProgressView().tint(.white.opacity(0.5))
                    @unknown default:
                        Color.clear
                    }
                }
            } else if let local {
                Image(uiImage: local).resizable().scaledToFill().blur(radius: 22).opacity(0.55)
                Image(uiImage: local).resizable().scaledToFit()
            } else {
                Image(systemName: isAudio ? "music.note" : "film")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: loadKey) {
            guard !usingRemote, local == nil else { return }
            local = await Self.load(thumbURL)
        }
    }

    private var loadKey: String { "\(thumbURL.path)|\(usingRemote)" }

    static func load(_ url: URL) async -> UIImage? {
        let path = url.path
        return await Task.detached(priority: .utility) { UIImage(contentsOfFile: path) }.value
    }
}
