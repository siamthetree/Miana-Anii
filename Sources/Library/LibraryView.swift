enum LibrarySort: String, CaseIterable, Identifiable { case recent = "Recently Added", title = "Title", lastPlayed = "Last Played"; var id: String { rawValue } }

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var sort: LibrarySort = .recent

    @State private var playing: MediaItem?
    @State private var detailedItem: MediaItem?

    @State private var renaming: MediaItem?
    @State private var renameText = ""

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .audio, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg, .mpeg2Video]
        for ext in ["mkv", "webm", "ts", "m2ts", "flv", "wmv", "srt", "vtt", "flac", "ogg", "opus"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
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
                    sortMenu; Button { showImporter = true } label: { Image(systemName: "plus") }; Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { r in if case .success(let urls) = r { Task { await store.importFiles(urls) } } }
        .fullScreenCover(item: $playing) { item in PlayerScreen(item: item, store: store) }
        .sheet(item: $detailedItem) { item in MediaDetailView(item: item, playingItem: $playing) }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText); Button("Save") { if let item = renaming { store.rename(item, to: renameText) }; renaming = nil }; Button("Cancel", role: .cancel) { renaming = nil }
        }
        .task { await store.rescan() }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await store.rescan() } } }
    }

    private var libraryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if searchText.isEmpty && !continueItems.isEmpty { sectionHeader("Continue Watching"); continueRow }
                sectionHeader(searchText.isEmpty ? "Library" : "Results"); grid
            }.padding(.horizontal).padding(.top, 6).padding(.bottom, 32)
        }
    }

    private func sectionHeader(_ text: String) -> some View { Text(text).font(.title3.weight(.semibold)).foregroundStyle(.white) }
    private var continueRow: some View { ScrollView(.horizontal, showsIndicators: false) { LazyHStack(alignment: .top, spacing: 14) { ForEach(continueItems) { item in Button { detailedItem = item } label: { ContinueCard(item: item, thumbURL: store.thumbURL(for: item)) }.buttonStyle(.plain).contextMenu { contextButtons(for: item) } } } } }
    private var grid: some View { LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 16)], alignment: .leading, spacing: 22) { ForEach(filteredItems) { item in Button { detailedItem = item } label: { MediaCard(item: item, thumbURL: store.thumbURL(for: item)) }.buttonStyle(.plain).contextMenu { contextButtons(for: item) } } } }

    @ViewBuilder
    private func contextButtons(for item: MediaItem) -> some View {
        Button { playing = item } label: { Label("Play", systemImage: "play.fill") }
        Button { store.resetProgress(item); playing = item } label: { Label("Play from Beginning", systemImage: "gobackward") }
        Button { renameText = item.title; renaming = item } label: { Label("Rename", systemImage: "pencil") }
        if item.isWatched { Button { store.resetProgress(item) } label: { Label("Mark as Unwatched", systemImage: "eye.slash") } }
        else if item.duration > 0 { Button { store.markWatched(item) } label: { Label("Mark as Watched", systemImage: "eye") } }
        Button(role: .destructive) { store.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    private var sortMenu: some View { Menu { Picker("Sort", selection: $sort) { ForEach(LibrarySort.allCases) { s in Text(s.rawValue).tag(s) } } } label: { Image(systemName: "arrow.up.arrow.down") } }
    private var emptyState: some View { VStack(spacing: 18) { Image(systemName: "film.stack").font(.system(size: 64)).foregroundStyle(.purple); Text("Your library is empty").font(.title2.weight(.semibold)); Text("Import videos with the + button, share files to Mina Anii from any app, or drop them into On My iPad › Mina Anii using the Files app.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420); Button { showImporter = true } label: { Label("Import Media", systemImage: "plus").padding(.horizontal, 8) }.buttonStyle(.borderedProminent) }.padding().frame(maxWidth: .infinity, maxHeight: .infinity) }

    private var continueItems: [MediaItem] { store.items.filter { $0.lastPosition > 20 && $0.duration > 0 && !$0.isWatched }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) } }
    private var filteredItems: [MediaItem] {
        var result = store.items
        if !searchText.isEmpty { result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.fileName.localizedCaseInsensitiveContains(searchText) } }
        switch sort {
        case .recent: result.sort { $0.dateAdded > $1.dateAdded }; case .title: result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }; case .lastPlayed: result.sort { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
        return result
    }
}

// MARK: - Cards

struct MediaCard: View {
    let item: MediaItem; let thumbURL: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit).overlay(ThumbImage(url: thumbURL, isAudio: item.isAudio, metadata: item.metadata)).clipped()
                if item.progress > 0.01 && !item.isWatched { GeometryReader { geo in Rectangle().fill(Color.purple).frame(width: geo.size.width * item.progress, height: 4).frame(maxHeight: .infinity, alignment: .bottom) } }
            }
            .overlay(alignment: .topTrailing) { if item.duration > 0 { Text(formatTime(item.duration)).font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.65), in: Capsule()).padding(6) } }
            .overlay(alignment: .topLeading) { if !item.isEngineSupported { Text(item.fileExtension.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.black).padding(.horizontal, 6).padding(.vertical, 3).background(.orange.opacity(0.9), in: Capsule()).padding(6) } }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(item.metadata?.title ?? item.title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.white)
            if let isTV = item.metadata?.isTVShow, isTV, let s = item.metadata?.season, let e = item.metadata?.episode { Text("Season \(s) • Episode \(e)").font(.caption2.weight(.bold)).foregroundStyle(.purple) }
            if let overview = item.metadata?.overview, !overview.isEmpty { Text(overview).font(.caption2).lineLimit(2).foregroundStyle(.secondary) } else { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var caption: String { if item.isWatched { return "Watched" }; if item.progress > 0.01, item.duration > 0 { return "\(formatTime(max(item.duration - item.lastPosition, 0))) left" }; return item.fileExtension.uppercased() }
}

struct ContinueCard: View {
    let item: MediaItem; let thumbURL: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.frame(width: 256, height: 144).overlay(ThumbImage(url: thumbURL, isAudio: item.isAudio, metadata: item.metadata)).clipped()
                    .overlay(Image(systemName: "play.circle.fill").font(.system(size: 42)).foregroundStyle(.white.opacity(0.92)))
                Rectangle().fill(Color.white.opacity(0.25)).frame(height: 4); Rectangle().fill(Color.purple).frame(width: 256 * item.progress, height: 4)
            }.clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.metadata?.title ?? item.title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.white)
            Text("\(formatTime(max(item.duration - item.lastPosition, 0))) left").font(.caption).foregroundStyle(.secondary)
        }.frame(width: 256)
    }
}

struct ThumbImage: View {
    let url: URL; var isAudio: Bool = false; var metadata: MediaMetadata? = nil
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
                if let posterURL = metadata?.posterURL {
                    AsyncImage(url: posterURL) { phase in if let img = phase.image { img.resizable().scaledToFill() } else { ProgressView() } }
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: isAudio ? "music.note" : "film").font(.system(size: 30)).foregroundStyle(.secondary)
                }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
        }.task(id: url) { if metadata?.posterURL == nil { image = await Self.load(url) } }
    }
    static func load(_ url: URL) async -> UIImage? { let path = url.path; return await Task.detached(priority: .utility) { UIImage(contentsOfFile: path) }.value }
