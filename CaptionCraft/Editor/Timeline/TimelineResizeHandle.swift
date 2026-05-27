import AppKit
import SwiftUI

/// タイムライン領域の上端に置くリサイズハンドル。
/// 上方向にドラッグすると高さが増え、下方向で減る。
struct TimelineResizeHandle: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var isDragging = false
    @State private var isHovering = false
    @State private var heightAtDragStart: CGFloat = 0

    var body: some View {
        ZStack {
            EditorTheme.chrome

            Rectangle()
                .fill(handleColor)
                .frame(height: isDragging ? 3 : 1)
        }
        .frame(height: 8)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        heightAtDragStart = height
                    }
                    // SwiftUI座標: Y下向き正。上ドラッグ→translation.height負→高さ増加
                    let newHeight = heightAtDragStart - value.translation.height
                    height = max(minHeight, min(maxHeight, newHeight))
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }

    private var handleColor: Color {
        if isDragging { return Color.cyan.opacity(0.7) }
        if isHovering { return Color.white.opacity(0.3) }
        return EditorTheme.divider
    }
}
