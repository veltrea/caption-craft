import AppKit
import SwiftUI

// MARK: - ScrollEventReceiver

/// 透明 NSView を前面 overlay として被せ、scrollWheel と mouseDown を一手に受け取る
/// SwiftUI 用のブリッジ。
///
/// 成熟度: experimental
///
/// なぜ NSView でやるのか:
/// - SwiftUI の `ScrollView` だと trackpad の横スクロール捕捉や `scrollTo` の挙動が
///   不安定 (特に `ZStack` 内 anchor で効かない)。
/// - SwiftUI 単独では mouse カーソル位置に応じた scrollWheel の選択的捕捉ができない。
/// - AppKit の `NSView.scrollWheel` は responder chain で確実に届くため、
///   「波形領域上にカーソルがあるときだけ横スクロール、それ以外は素通り」を
///   素直に書ける。
///
/// 使い方:
/// ```swift
/// ZStack { WaveformView(...) }
///   .overlay(
///     ScrollEventReceiver(
///       onScroll: { dx in offset += dx },
///       onClick:  { point in handleTap(point) }
///     )
///   )
/// ```
struct ScrollEventReceiver: NSViewRepresentable {

    /// scrollWheel から抽出した横方向 delta (px)。
    /// 正の値 = 「コンテンツを右へ進める」(右側を見る) 方向。
    let onScroll: (CGFloat) -> Void

    /// マウスクリック (mouseDown) 時に view 内座標を返す。
    /// 座標系は SwiftUI 慣例 (origin 左上、Y 下向き)。nil なら click ハンドリング無し。
    let onClick: ((CGPoint) -> Void)?

    /// mouseDown 後のドラッグ中に毎フレーム呼ばれる。
    let onDrag: ((CGPoint) -> Void)?

    /// mouseUp 時に呼ばれる (ドラッグ終了)。
    let onDragEnd: (() -> Void)?

    /// マウスカーソル移動時に呼ばれる (ホバー検出用)。
    let onHover: ((CGPoint) -> Void)?

    /// 右クリック時に view 内座標を返す (コンテキストメニュー用)。
    let onRightClick: ((CGPoint) -> Void)?

    /// Option+ドラッグ開始時に view 内座標を返す (リージョン新規追加用)。
    let onOptionDragStart: ((CGPoint) -> Void)?
    /// Option+ドラッグ中に view 内座標を返す。
    let onOptionDragMove: ((CGPoint) -> Void)?
    /// Option+ドラッグ終了時に呼ばれる。
    let onOptionDragEnd: (() -> Void)?

    init(
        onScroll: @escaping (CGFloat) -> Void,
        onClick: ((CGPoint) -> Void)? = nil,
        onDrag: ((CGPoint) -> Void)? = nil,
        onDragEnd: (() -> Void)? = nil,
        onHover: ((CGPoint) -> Void)? = nil,
        onRightClick: ((CGPoint) -> Void)? = nil,
        onOptionDragStart: ((CGPoint) -> Void)? = nil,
        onOptionDragMove: ((CGPoint) -> Void)? = nil,
        onOptionDragEnd: (() -> Void)? = nil
    ) {
        self.onScroll = onScroll
        self.onClick = onClick
        self.onDrag = onDrag
        self.onDragEnd = onDragEnd
        self.onHover = onHover
        self.onRightClick = onRightClick
        self.onOptionDragStart = onOptionDragStart
        self.onOptionDragMove = onOptionDragMove
        self.onOptionDragEnd = onOptionDragEnd
    }

    func makeNSView(context: Context) -> ScrollCatcherView {
        let v = ScrollCatcherView()
        v.onScroll = onScroll
        v.onClick = onClick
        v.onDrag = onDrag
        v.onDragEnd = onDragEnd
        v.onHover = onHover
        v.onRightClick = onRightClick
        v.onOptionDragStart = onOptionDragStart
        v.onOptionDragMove = onOptionDragMove
        v.onOptionDragEnd = onOptionDragEnd
        return v
    }

    func updateNSView(_ view: ScrollCatcherView, context: Context) {
        view.onScroll = onScroll
        view.onClick = onClick
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.onHover = onHover
        view.onRightClick = onRightClick
        view.onOptionDragStart = onOptionDragStart
        view.onOptionDragMove = onOptionDragMove
        view.onOptionDragEnd = onOptionDragEnd
    }

    final class ScrollCatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        var onClick: ((CGPoint) -> Void)?
        var onDrag: ((CGPoint) -> Void)?
        var onDragEnd: (() -> Void)?
        var onHover: ((CGPoint) -> Void)?
        var onRightClick: ((CGPoint) -> Void)?
        var onOptionDragStart: ((CGPoint) -> Void)?
        var onOptionDragMove: ((CGPoint) -> Void)?
        var onOptionDragEnd: (() -> Void)?

        /// Option+mouseDown で開始した場合 true。
        /// mouseDragged / mouseUp のルーティングに使う。
        private var isOptionDragging = false

        override var acceptsFirstResponder: Bool { false }

        // hitTest: 自分を返さないと scrollWheel も mouseDown も来ない (AppKit 仕様)。
        override func hitTest(_ point: NSPoint) -> NSView? { return self }

        // ホバー検出用のトラッキング領域を自動更新
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override func scrollWheel(with event: NSEvent) {
            let dx: CGFloat
            let dy: CGFloat
            if event.hasPreciseScrollingDeltas {
                dx = event.scrollingDeltaX
                dy = event.scrollingDeltaY
            } else {
                // line-based delta (普通のマウスホイール) は粗いので増幅
                dx = event.deltaX * 10
                dy = event.deltaY * 10
            }
            // 横優先: 横が大きければ横、小さければ縦を横に変換
            // 通常マウスホイールは縦しか出ないが、波形タイムライン上では横スクロール扱い
            let primary: CGFloat = abs(dx) >= abs(dy) ? -dx : -dy
            onScroll?(primary)
        }

        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            let pt = CGPoint(x: p.x, y: p.y)
            if event.modifierFlags.contains(.option) {
                isOptionDragging = true
                onOptionDragStart?(pt)
            } else {
                isOptionDragging = false
                onClick?(pt)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            let pt = CGPoint(x: p.x, y: p.y)
            if isOptionDragging {
                onOptionDragMove?(pt)
            } else {
                onDrag?(pt)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if isOptionDragging {
                isOptionDragging = false
                onOptionDragEnd?()
            } else {
                onDragEnd?()
            }
        }

        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            let pt = CGPoint(x: p.x, y: p.y)
            if event.modifierFlags.contains(.option) {
                NSCursor.crosshair.set()
            } else {
                onHover?(pt)
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            onRightClick?(CGPoint(x: p.x, y: p.y))
            super.rightMouseDown(with: event)
        }

        // SwiftUI と座標系を揃えるため flipped にする (origin 左上、Y 下向き)。
        override var isFlipped: Bool { true }
    }
}
