// ==========================================================
//  BUG 3  -  GROUP ONCE, NOT EIGHT TIMES A FRAME  (3 of 4)
//
//  File:  Sources/Library/SeriesDetailView.swift
//  Replace the entire file. Supersedes FIX-4c.
//
//  `current` is read about eight times per body. It was regrouping the
//  entire library each time. It is a dictionary lookup now.
// ==========================================================

import Foundation
import SwiftUI

struct SeriesDetailView: View {
    let series: Series
    @Binding var playingItem: MediaItem?

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// Live copy pulled from the store, so edits reflect immediately. A dictionary
    /// lookup now, not a regrouping of the whole library on every read.
    private var current: Series { store.series(withID: series.id) ?? series }
    private var seasons: [Season] { current.seasons }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    VStack(alignment: .leading, spacing: 30) {
                        playButton
                        seasonsSection
                        if !current.overview.isEmpty { synopsis(current.overview) }
                        if !current.cast.isEmpty { castSection(current.cast) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }
            .background(Color(white: 0.06).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Int.self) { number in
                SeasonDetailView(seriesID: current.id, seasonNumber: number, play: play, close: { dismiss() })
            }
            .navigationDestination(for: MediaItem.self) { item in
                EpisodeDetailView(itemID: item.id, play: play)
            }
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.6), .black.opacity(0.4))
                }
                .padding()
            }
        }
    }

    private func play(_ item: MediaItem) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { playingItem = item }
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
            .overlay(LinearGradient(colors: [.clear, Color(white: 0.06)], startPoint: .center, endPoint: .bottom))

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
                            Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.yellow)
                        }
                        if current.unwatchedCount > 0 { Text("\(current.unwatchedCount) unwatched") }
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

    // MARK: - Seasons

    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Seasons").font(.title3.weight(.bold)).foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(seasons) { season in
                        NavigationLink(value: season.number) {
                            SeasonCard(season: season)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
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
}

// MARK: - Season card

struct SeasonCard: View {
    let season: Season

    private let width: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .frame(width: width, height: width * 3 / 2)
                .overlay(SeriesPoster(posterURL: season.posterURL))
                .overlay(alignment: .bottomLeading) {
                    if season.unwatchedCount > 0 {
                        Text("\(season.unwatchedCount) new")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.purple, in: Capsule())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.4), radius: 5, y: 3)

            Text(season.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)

            Text(season.episodeCountText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
    }
}
