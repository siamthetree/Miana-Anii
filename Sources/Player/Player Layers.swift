
import Foundation
import SwiftUI
import AVFoundation
import AVKit
import Combine
import UIKit
import UniformTypeIdentifiers
import MobileVLCKit

final class PlayerLayerHolder { weak var playerLayer: AVPlayerLayer? }

final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer; let holder: PlayerLayerHolder; let gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        holder.playerLayer = view.playerLayer
        return view
    }
    func updateUIView(_ uiView: PlayerContainerView, context: Context) { uiView.playerLayer.videoGravity = gravity }
}

struct VLCPlayerLayerView: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.backgroundColor = .black; player.drawable = view; return view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemPurple
        view.prioritizesVideoDevices = true
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Window chrome detection

struct WindowChromeProbe: UIViewRepresentable {
    @Binding var isWindowed: Bool

    final class Probe: UIView {
        var onChange: ((Bool) -> Void)?
        private var lastValue: Bool?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window, let screen = window.windowScene?.screen else { return }

            let frame = window.frame
            let bounds = screen.bounds
            let windowed = frame.width < bounds.width - 1 && frame.height < bounds.height - 1

            guard windowed != lastValue else { return }
            lastValue = windowed

            let handler = onChange
            DispatchQueue.main.async { handler?(windowed) }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = { isWindowed = $0 }
        return view
    }

    func updateUIView(_ uiView: Probe, context: Context) {
        uiView.onChange = { isWindowed = $0 }
    }
}
