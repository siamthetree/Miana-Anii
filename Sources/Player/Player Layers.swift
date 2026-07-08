import Foundation
import SwiftUI
import AVFoundation
import AVKit
import Combine
import UIKit
import UniformTypeIdentifiers
import MobileVLCKit

final class PlayerLayerHolder { weak var playerLayer: AVPlayerLayer? }
final class PlayerContainerView: UIView { override static var layerClass: AnyClass { AVPlayerLayer.self }; var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } }
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer; let holder: PlayerLayerHolder; let gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> PlayerContainerView { let view = PlayerContainerView(); view.backgroundColor = .black; view.playerLayer.player = player; view.playerLayer.videoGravity = gravity; holder.playerLayer = view.playerLayer; return view }
    func updateUIView(_ uiView: PlayerContainerView, context: Context) { uiView.playerLayer.videoGravity = gravity }
}
struct VLCPlayerLayerView: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.backgroundColor = .black; player.drawable = view; return view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.tintColor = .white; view.activeTintColor = .systemPurple; view.prioritizesVideoDevices = true; return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
