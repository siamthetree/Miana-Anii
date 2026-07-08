import SwiftUI
import MobileVLCKit

struct VideoPlayerView: UIViewControllerRepresentable {
    let item: MediaItem

    func makeUIViewController(context: Context) -> VLCViewController {
        let controller = VLCViewController()
        controller.mediaURL = item.fileURL
        return controller
    }

    func updateUIViewController(_ uiViewController: VLCViewController, context: Context) {}
}

class VLCViewController: UIViewController, VLCMediaPlayerDelegate {
    var mediaPlayer = VLCMediaPlayer()
    var mediaURL: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        mediaPlayer.drawable = self.view
        mediaPlayer.delegate = self
        
        if let url = mediaURL {
            let media = VLCMedia(url: url)
            mediaPlayer.media = media
            mediaPlayer.play()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        mediaPlayer.stop()
    }
}
