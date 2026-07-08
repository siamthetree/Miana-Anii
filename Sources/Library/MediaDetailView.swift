Import Foundation
struct MediaDetailView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @Binding var playingItem: MediaItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    if let backdrop = item.metadata?.backdropURL {
                        AsyncImage(url: backdrop) { phase in if let img = phase.image { img.resizable().scaledToFill() } else { Color(white: 0.12) } }
                        .frame(height: 380).clipped().overlay(LinearGradient(colors: [.clear, Color(white: 0.06)], startPoint: .center, endPoint: .bottom))
                    } else { Color(white: 0.12).frame(height: 380).overlay(LinearGradient(colors: [.clear, Color(white: 0.06)], startPoint: .center, endPoint: .bottom)) }

                    HStack(alignment: .bottom, spacing: 20) {
                        if let poster = item.metadata?.posterURL {
                            AsyncImage(url: poster) { phase in if let img = phase.image { img.resizable().scaledToFit() } else { Color(white: 0.2) } }
                            .frame(width: 140, height: 210).clipShape(RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.metadata?.title ?? item.title).font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                            if let isTV = item.metadata?.isTVShow, isTV, let s = item.metadata?.season, let e = item.metadata?.episode { Text("Season \(s) • Episode \(e)").font(.headline).foregroundStyle(.purple) }
                            HStack(spacing: 14) {
                                if let year = item.metadata?.releaseYear, !year.isEmpty { Text(year) }
                                if let rating = item.metadata?.rating, rating > 0 { Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.yellow) }
                                Text(formatTime(item.duration))
                                Text(item.fileExtension.uppercased()).font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                            }.font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.8))

                            if let genres = item.metadata?.genres, !genres.isEmpty { Text(genres.joined(separator: " • ")).font(.caption).foregroundStyle(.white.opacity(0.6)) }
                        }.padding(.bottom, 10)
                    }.padding(.horizontal, 24).offset(y: 40)
                }

                VStack(alignment: .leading, spacing: 30) {
                    HStack(spacing: 16) {
                        Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { playingItem = item } } label: {
                            let isResuming = item.progress > 0.01 && !item.isWatched
                            Label(isResuming ? "Resume" : "Play", systemImage: "play.fill").font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 14).background(Color.purple).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(.top, 60)

                    if let overview = item.metadata?.overview, !overview.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("Synopsis").font(.title3.weight(.bold)).foregroundStyle(.white); Text(overview).font(.body).lineSpacing(4).foregroundStyle(.white.opacity(0.8)) } }

                    if let cast = item.metadata?.cast, !cast.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Cast").font(.title3.weight(.bold)).foregroundStyle(.white)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) { ForEach(cast, id: \.self) { actor in Text(actor).font(.subheadline).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10).background(Color.white.opacity(0.1)).clipShape(Capsule()) } }
                            }
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 40)
            }
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        .overlay(alignment: .topTrailing) { Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 32)).foregroundStyle(.white.opacity(0.6), .black.opacity(0.4)) }.padding() }
    }
}
