import AVFoundation
import AppKit
import SwiftUI

/// AVPlayer の映像を表示する NSView をラップする。
///
/// CC Phase 03 で動画装飾系 (border radius, shadow, zoom transform / cursor 追従ズーム) を
/// 全削除した。CaptionCraft では字幕プレビューに必要な「動画を bounds に等比で表示する」
/// ことだけ行う最小実装。`zoomTransform` 引数は呼び出し側互換のため残しているが、
/// 実装は無視する (常に identity)。
struct VideoLayerView: NSViewRepresentable {
    let player: AVPlayer
    var borderRadius:    CGFloat = 0
    var shadowIntensity: CGFloat = 0
    var zoomTransform:   ZoomTransform = .identity

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.attach(player: player)
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.attach(player: player)
    }

    // MARK: - Container

    final class PlayerContainerView: NSView {
        private let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        func attach(player: AVPlayer) {
            if playerLayer.player !== player {
                playerLayer.player = player
            }
        }

        private func configure() {
            wantsLayer = true
            layer = CALayer()
            playerLayer.videoGravity    = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
