import Foundation
import SwiftUI

struct SeasonDetailView: View {
    let seriesID: String
    let seasonNumber: Int
    let play: (MediaItem) -> Void
    let close: () -> Void

    @EnvironmentObject private var store: LibraryStore

    private var series: Series? { store.items.series(withID: seriesID) }
    private var season: Season? { series?.seasons.first(where: { $0.number == seasonNumber }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let season { header(season); episodeList(season) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        .navigationTitle(season?.displayName ?? "Season \(seasonNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { close() } }
        }
    }

    // MARK: - Header

    private func header(_ season: Season) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                Color.clear
                    .frame(width: 120, height: 180)
                    .overlay(SeriesPoster(posterURL: season.posterURL))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 8) {
                    if let show = series {
                        Text(show.title).font(.headline).foregroundStyle(.white.opacity(0.7))
                    }
                    Text(season.displayName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)

                    Text(season.unwatchedCount > 0
                         ? "\(season.episodeCountText) • \(season.unwatchedCount) unwatched"
                         : season.episodeCountText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let next = season.nextUp {
                        Button { play(next) } label: {
                            Label("Play \(next.episodeCode)", systemImage: "play.fill")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(Color.purple, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)
            }

            if let overview = season.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    // MARK: - Episodes

    private func episodeList(_ season: Season) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Episodes").font(.title3.weight(.bold)).foregroundStyle(.white)

            VStack(spacing: 0) {
                ForEach(season.episodes) { episode in
                    EpisodeRow(item: episode,
                               thumbURL: store.thumbURL(for: episode),
                               play: { play(episode) })
                        .contextMenu { episodeButtons(for: episode) }

                    if episode.id != season.episodes.last?.id {
                        Divider().background(Color.white.opacity(0.08))
                    }
                }
            }
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private func episodeButtons(for item: MediaItem) -> some View {
        Button { play(item) } label: { Label("Play", systemImage: "play.fill") }
        Button { store.resetProgress(item); play(item) } label: { Label("Play from Beginning", systemImage: "gobackward") }
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
    let play: () -> Void

    private let thumbWidth: CGFloat = 150

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: play) { thumbnail }
                .buttonStyle(.plain)

            NavigationLink(value: item) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(item.episodeNumber > 0 ? "\(item.episodeNumber)" : "•")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.purple)
                            .frame(minWidth: 16, alignment: .leading)

                        Text(item.displayEpisodeTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if item.isWatched {
                            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.purple)
                        }
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    }

                    Text(subtitle).font(.caption).foregroundStyle(.secondary)

                    if let overview = item.episodeOverview {
                        Text(overview)
                            .font(.caption)
                            .lineLimit(2)
                            .lineSpacing(2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    private var thumbnail: some View {
        Color.clear
            .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
            .overlay(ArtworkImage(thumbURL: thumbURL, remoteURL: item.stillURL, isAudio: item.isAudio))
            .overlay(Color.black.opacity(0.12))
            .overlay(Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.9)))
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
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let air = item.formattedAirDate { parts.append(air) }
        if item.isWatched { parts.append("Watched") }
        else if item.progress > 0.01, item.duration > 0 {
            parts.append("\(formatTime(max(item.duration - item.lastPosition, 0))) left")
        } else if item.duration > 0 {
            parts.append(formatTime(item.duration))
        }
        if parts.isEmpty { parts.append(item.fileExtension.uppercased()) }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Episode detail

struct EpisodeDetailView: View {
    let itemID: UUID
    let play: (MediaItem) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private var item: MediaItem? { store.items.first(where: { $0.id == itemID }) }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay(ArtworkImage(thumbURL: store.thumbURL(for: item),
                                              remoteURL: item.stillURL,
                                              isAudio: item.isAudio))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.episodeCode)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.purple)

                        Text(item.displayEpisodeTitle)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        Text(metaLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button { play(item) } label: {
                        let resuming = item.progress > 0.01 && !item.isWatched
                        Label(resuming ? "Resume" : "Play", systemImage: "play.fill")
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.purple)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    if item.progress > 0.01 {
                        Button { store.resetProgress(item); play(item) } label: {
                            Label("Play from Beginning", systemImage: "gobackward")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.1))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }

                    if let overview = item.episodeOverview {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Synopsis").font(.headline).foregroundStyle(.white)
                            Text(overview).font(.body).lineSpacing(4).foregroundStyle(.white.opacity(0.8))
                        }
                    }

                    HStack(spacing: 12) {
                        if item.isWatched {
                            Button("Mark as Unwatched") { store.resetProgress(item) }
                        } else if item.duration > 0 {
                            Button("Mark as Watched") { store.markWatched(item) }
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { store.delete(item); dismiss() }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        .navigationTitle(item?.episodeCode ?? "Episode")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var metaLine: String {
        guard let item else { return "" }
        var parts: [String] = []
        if let air = item.formattedAirDate { parts.append(air) }
        if item.duration > 0 { parts.append(formatTime(item.duration)) }
        if item.isWatched { parts.append("Watched") }
        else if item.progress > 0.01 { parts.append("\(formatTime(max(item.duration - item.lastPosition, 0))) left") }
        parts.append(item.fileExtension.uppercased())
        return parts.joined(separator: " • ")
    }
}
