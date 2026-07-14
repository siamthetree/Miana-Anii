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
    let player: AVPlayer
    let holder: PlayerLayerHolder
    let gravity: AVLayerVideoGravity
    
    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        holder.playerLayer = view.playerLayer
        return view
    }
    
    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.videoGravity = gravity
    }
}

// MARK: - VLC Scale Implementation

struct VLCPlayerLayerView: UIViewRepresentable {
    let player: VLCMediaPlayer
    let scaleMode: VideoScaleMode
    
    func makeUIView(context: Context) -> VLCVideoContainerView {
        let view = VLCVideoContainerView()
        view.backgroundColor = .black
        view.player = player
        player.drawable = view
        return view
    }
    
    func updateUIView(_ uiView: VLCVideoContainerView, context: Context) {
        uiView.scaleMode = scaleMode
    }
}

final class VLCVideoContainerView: UIView {
    weak var player: VLCMediaPlayer?
    
    var scaleMode: VideoScaleMode = .fit {
        didSet {
            if oldValue != scaleMode { applyScale() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyScale()
    }

    private func applyScale() {
        guard let player = player else { return }
        
        // Calculate the exact screen ratio for precise VLC scaling/cropping
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        
        // Ensure layout has actually been calculated before forcing a ratio
        guard width > 0 && height > 0 else { return }
        
        let ratioString = "\(width):\(height)"
        
        switch scaleMode {
        case .fit:
            player.videoCropGeometry = nil
            player.videoAspectRatio = nil
            
        case .fill:
            // Crop the video overflow to fill the screen bounds completely
            player.videoCropGeometry = UnsafeMutablePointer<Int8>(mutating: (ratioString as NSString).utf8String)
            player.videoAspectRatio = nil
            
        case .stretch:
            // Stretch the video geometry to force it to screen bounds (ignores aspect ratio)
            player.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: (ratioString as NSString).utf8String)
            player.videoCropGeometry = nil
        }
    }
}

// MARK: - Route Picker & Window Probes

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
