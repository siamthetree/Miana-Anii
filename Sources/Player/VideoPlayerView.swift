import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let item: MediaItem
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                ProgressView("Loading video…")
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            player = AVPlayer(url: item.fileURL)
        }
    }
}
