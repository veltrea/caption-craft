import CoreGraphics

/// プレビュー canvas 上の「映像が実際に描画されている矩形」を計算するヘルパ。
///
/// VideoLayerView は `.padding(editorState.padding)` の内側で `videoGravity = .resizeAspect`
/// により映像を中央配置する。マウス座標オーバーレイ (CursorHighlight / ClickRipple /
/// MouseTrajectory) は外側 canvas 全体に配置されるため、正規化座標 (0..1) を単純に
/// `canvas.width / canvas.height` で掛け算すると映像の外側に描画されてしまう
/// (FIX_18 Phase 3 座標ズレバグ)。
///
/// このヘルパは canvas / padding / 録画映像サイズ の 3 情報から、映像が実描画されて
/// いる内側矩形 (`videoRect`) を算出し、正規化座標 → canvas ピクセル座標への
/// 変換 (`canvasPoint`) を提供する。全てのマウス系オーバーレイはこの変換を通すこと。
///
/// 成熟度: experimental (FIX_18 Phase 3 で新設)
struct PreviewCanvasGeometry {

    /// PreviewAreaView の `fittedCanvas` 結果。16:9 等のアスペクト比に合わせて
    /// ジオメトリ領域に内接するように算出済み。
    let canvasSize: CGSize

    /// EditorState.padding (pt)。VideoLayerView の上下左右に均等に適用される。
    let padding: CGFloat

    /// 録画映像のピクセルサイズ。`.resizeAspect` のレターボックス/ピラーボックス計算に使う。
    /// 未ロード時は canvas アスペクトと同じと仮定して null でも動くよう設計する。
    let videoSize: CGSize

    /// 映像が実描画されている矩形 (canvas 座標系、左上原点)。
    /// padding 内側の矩形に対して videoSize のアスペクトで .resizeAspect fit する。
    var videoRect: CGRect {
        let paddedWidth  = max(0, canvasSize.width  - padding * 2)
        let paddedHeight = max(0, canvasSize.height - padding * 2)
        guard paddedWidth > 0, paddedHeight > 0 else {
            return CGRect(x: padding, y: padding, width: 0, height: 0)
        }
        // videoSize が 0 の場合 (未ロード等) は padded rect をそのまま返す。
        guard videoSize.width > 0, videoSize.height > 0 else {
            return CGRect(x: padding, y: padding, width: paddedWidth, height: paddedHeight)
        }

        let videoAspect  = videoSize.width / videoSize.height
        let paddedAspect = paddedWidth / paddedHeight

        let fittedWidth:  CGFloat
        let fittedHeight: CGFloat
        if videoAspect > paddedAspect {
            // padded より映像のほうが横長 → 幅に合わせて上下にレターボックス
            fittedWidth  = paddedWidth
            fittedHeight = paddedWidth / videoAspect
        } else {
            // padded より映像のほうが縦長 → 高さに合わせて左右にピラーボックス
            fittedHeight = paddedHeight
            fittedWidth  = paddedHeight * videoAspect
        }
        let x = padding + (paddedWidth  - fittedWidth)  / 2
        let y = padding + (paddedHeight - fittedHeight) / 2
        return CGRect(x: x, y: y, width: fittedWidth, height: fittedHeight)
    }

    /// 正規化座標 (録画フレーム基準 0..1) → canvas 座標系のピクセル位置に変換する。
    /// 範囲外の (x, y) も線形延長する (ウィンドウ録画で外側クリックを可視化したいため)。
    func canvasPoint(forNormalizedX nx: Double, y ny: Double) -> CGPoint {
        let r = videoRect
        return CGPoint(
            x: r.minX + CGFloat(nx) * r.width,
            y: r.minY + CGFloat(ny) * r.height
        )
    }
}
