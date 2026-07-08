import Foundation
import SwiftUI

struct SeriesDetailView: View {
    let series: Series
    @Binding var playingItem: MediaItem?

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSeason: Int
    @State private var renaming: MediaItem?
    @State private var renameText = ""

    init(series: Series, playingItem: Binding<MediaItem?>) {
        self.series = series
        self._playingItem = playingItem
        let seasons = series.seasons
        let firstUnfinished = seasons.first(where: { $0.unwatchedCount > 0 })?.number
        _selectedSeason = State(initialValue: firstUnfinished ?? seasons.first?.number ?? 1)
    }

    /// Live copy pulled from the store, so edits reflect immediately.
    private var current: Series {
        for entry in store.items.groupedIntoEntries() {
            if case .series(let show) = entry, show.id == series.id { return show }
        }
        return series
    }

    private var seasons: [Season] { current.seasons }
    private var activeSeason: Season? {
        seasons.first(where: { $0.number == selectedSeason }) ?? seasons.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(alignment: .leading, spacing: 30) {
                    playButton

                    if !current.overview.isEmpty { synopsis(current.overview) }
                    if !current.cast.isEmpty { castSection(current.cast) }

                    episodeSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.6), .black.opacity(0.4))
            }
            .padding()
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { if let item = renaming { store.rename(item, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let backdrop = current.backdropURL {
                    AsyncImage(url: backdrop) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { Color(white: 0.12) }
                    }
                } else {
                    Color(white: 0.12)
                }
            }
            .frame(height: 380)
            .clipped()
            .overlay(
                LinearGradient(colors: [.clear, Color(white: 0.06)], startPoint: .center, endPoint: .bottom)
            )

            HStack(alignment: .bottom, spacing: 20) {
                if let poster = current.posterURL {
                    AsyncImage(url: poster) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { Color(white: 0.2) }
                    }
                    .frame(width: 140, height: 210)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(current.title)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)

                    Text(current.subtitle)
                        .font(.headline)
                        .foregroundStyle(.purple)

                    HStack(spacing: 14) {
                        if !current.releaseYear.isEmpty { Text(current.releaseYear) }
                        if let rating = current.rating, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        if current.unwatchedCount > 0 {
                            Text("\(current.unwatchedCount) unwatched")
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))

                    if !current.genres.isEmpty {
                        Text(current.genres.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
            .offset(y: 40)
        }
    }

    // MARK: - Play next up

    @ViewBuilder
    private var playButton: some View {
        if let next = current.nextUp {
            Button { play(next) } label: {
                let resuming = next.progress > 0.01 && !next.isWatched
                Label("\(resuming ? "Resume" : "Play") \(next.episodeCode)", systemImage: "play.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.purple)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 60)
        } else {
            Color.clear.frame(height: 60)
        }
    }

    private func play(_ item: MediaItem) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { playingItem = item }
    }

    // MARK: - Synopsis and cast

    private func synopsis(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synopsis").font(.title3.weight(.bold)).foregroundStyle(.white)
            Text(text).font(.body).lineSpacing(4).foregroundStyle(.white.opacity(0.8))
        }
    }

    private func castSection(_ cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast").font(.title3.weight(.bold)).foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(cast.enumerated()), id: \.offset) { entry in
                        CastCard(member: entry.element)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Episodes

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Episodes").font(.title3.weight(.bold)).foregroundStyle(.white)
                Spacer()
                if seasons.count > 1 { seasonMenu }
            }

            if let season = activeSeason {
                VStack(spacing: 0) {
                    ForEach(season.episodes) { episode in
                        Button { play(episode) } label: {
                            EpisodeRow(item: episode, thumbURL: store.thumbURL(for: episode))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { episodeButtons(for: episode) }

                        if episode.id != season.episodes.last?.id {
                            Divider().background(Color.white.opacity(0.08))
                        }
                    }
                }
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var seasonMenu: some View {
        Menu {
            ForEach(seasons) { season in
                Button {
                    selectedSeason = season.number
                } label: {
                    if season.number == selectedSeason {
                        Label("Season \(season.number)", systemImage: "checkmark")
                    } else {
                        Text("Season \(season.number)")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Season \(activeSeason?.number ?? selectedSeason)")
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.white.opacity(0.1), in: Capsule())
        }
    }

    @ViewBuilder
    private func episodeButtons(for item: MediaItem) -> some View {
        Button { play(item) } label: { Label("Play", systemImage: "play.fill") }
        Button { store.resetProgress(item); play(item) } label: { Label("Play from Beginning", systemImage: "gobackward") }
        Button { renameText = item.title; renaming = item } label: { Label("Rename", systemImage: "pencil") }
        if item.isWatched {
            Button { store.resetProgress(item) } label: { Label("Mark as Unwatched", systemImage: "eye.slash") }
        } else if item.duration > 0 {
            Button { store.markWatched(item) } label: { Label("Mark as Watched", systemImage: "eye") }
        }
        Button(role: .destructive) { store.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }
}

// MARK: - Episode row

struct EpisodeRow: View {
    let item: MediaItem
    let thumbURL: URL

    private let thumbWidth: CGFloat = 150

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.episodeNumber > 0 ? "\(item.episodeNumber)" : "•")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.purple)
                        .frame(minWidth: 18, alignment: .leading)

                    Text(item.displayEpisodeTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if item.isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.purple)
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !item.isEngineSupported {
                    Text(item.fileExtension.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        Color.clear
            .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
            .overlay(ArtworkImage(thumbURL: thumbURL, remoteURL: nil, isAudio: item.isAudio))
            .overlay(alignment: .bottom) {
                if item.progress > 0.01 && !item.isWatched {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.45))
                            Rectangle().fill(Color.purple).frame(width: geo.size.width * item.progress)
                        }
                        .frame(height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .overlay(Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.85)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var subtitle: String {
        if item.isWatched { return "Watched • \(formatTime(item.duration))" }
        if item.progress > 0.01, item.duration > 0 {
            return "\(formatTime(max(item.duration - item.lastPosition, 0))) left"
        }
        return item.duration > 0 ? formatTime(item.duration) : item.fileExtension.uppercased()
    }
}
