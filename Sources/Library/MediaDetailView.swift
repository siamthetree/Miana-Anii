

import Foundation
import SwiftUI

struct MediaDetailView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @Binding var playingItem: MediaItem?

    private var meta: MediaMetadata? { item.metadata }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(alignment: .leading, spacing: 30) {
                    playButton

                    if let overview = meta?.overview, !overview.isEmpty {
                        synopsis(overview)
                    }

                    if let cast = meta?.cast, !cast.isEmpty {
                        castSection(cast)
                    }
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
    }

    // MARK: - Header (backdrop + poster + titles)

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let backdrop = meta?.backdropURL {
                    AsyncImage(url: backdrop) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            Color(white: 0.12)
                        }
                    }
                } else {
                    Color(white: 0.12)
                }
            }
            .frame(height: 380)
            .clipped()
            .overlay(
                LinearGradient(colors: [.clear, Color(white: 0.06)],
                               startPoint: .center, endPoint: .bottom)
            )

            HStack(alignment: .bottom, spacing: 20) {
                if let poster = meta?.posterURL {
                    AsyncImage(url: poster) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            Color(white: 0.2)
                        }
                    }
                    .frame(width: 140, height: 210)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                }

                titleBlock
            }
            .padding(.horizontal, 24)
            .offset(y: 40)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meta?.title ?? item.title)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)

            if let isTV = meta?.isTVShow, isTV,
               let s = meta?.season, let e = meta?.episode {
                Text("Season \(s) • Episode \(e)")
                    .font(.headline)
                    .foregroundStyle(.purple)
            }

            HStack(spacing: 14) {
                if let year = meta?.releaseYear, !year.isEmpty { Text(year) }
                if let rating = meta?.rating, rating > 0 {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(formatTime(item.duration))
                Text(item.fileExtension.uppercased())
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.8))

            if let genres = meta?.genres, !genres.isEmpty {
                Text(genres.joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - Play

    private var playButton: some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { playingItem = item }
            } label: {
                let isResuming = item.progress > 0.01 && !item.isWatched
                Label(isResuming ? "Resume" : "Play", systemImage: "play.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.purple)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.top, 60)
    }

    // MARK: - Synopsis

    private func synopsis(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synopsis")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text(text)
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: - Cast

    private func castSection(_ cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

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

// MARK: - Cast card

struct CastCard: View {
    let member: CastMember

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))

                if let url = member.profileURL {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.18))) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            initials
                        case .empty:
                            ProgressView().tint(.white.opacity(0.6))
                        @unknown default:
                            initials
                        }
                    }
                } else {
                    initials
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

            Text(member.name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 96)
        }
        .frame(width: 96)
    }

    private var initials: some View {
        Text(initialsText)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white.opacity(0.55))
    }

    private var initialsText: String {
        let letters = member.name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
