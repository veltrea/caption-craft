import AppKit
import SwiftUI

// MARK: - CaptionBandsNSView

/// 字幕リージョンを AppKit で描画する NSView。
/// SwiftUI の Canvas/Shape ではデータ変化のリフレッシュタイミングが
/// 不安定だったため、明示的に `needsDisplay = true` を呼べる
/// 伝統的な AppKit 描画に置き換えた。
final class CaptionBandsNSView: NSView {
    var regions: [CaptionRegion] = [] {
        didSet { needsDisplay = true }
    }
    var durationMs: Int = 0 {
        didSet { needsDisplay = true }
    }
    var selectedID: UUID? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard durationMs > 0, bounds.width > 0 else { return }
        let pxPerMs = bounds.width / CGFloat(durationMs)
        let h = bounds.height

        for region in regions {
            let x = CGFloat(region.startMs) * pxPerMs
            let w = max(1, CGFloat(region.endMs - region.startMs) * pxPerMs)
            let rect = NSRect(x: x, y: 0, width: w, height: h)

            let isSelected = (region.id == selectedID)
            let fillAlpha: CGFloat = isSelected ? 0.25 : 0.12
            let strokeAlpha: CGFloat = isSelected ? 0.9 : 0.45
            let lineWidth: CGFloat = isSelected ? 1.5 : 0.8

            NSColor.yellow.withAlphaComponent(fillAlpha).setFill()
            rect.fill()

            NSColor.yellow.withAlphaComponent(strokeAlpha).setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            path.stroke()
        }
    }
}

// MARK: - CaptionBandsView (SwiftUI wrapper)

struct CaptionBandsView: NSViewRepresentable {
    let regions: [CaptionRegion]
    let durationMs: Int
    let selectedID: UUID?

    func makeNSView(context: Context) -> CaptionBandsNSView {
        let view = CaptionBandsNSView()
        view.regions = regions
        view.durationMs = durationMs
        view.selectedID = selectedID
        return view
    }

    func updateNSView(_ nsView: CaptionBandsNSView, context: Context) {
        // ここが SwiftUI から AppKit にデータを伝える経路。
        // 値が変わった時にだけ needsDisplay = true を発火させる。
        if nsView.regions != regions { nsView.regions = regions }
        if nsView.durationMs != durationMs { nsView.durationMs = durationMs }
        if nsView.selectedID != selectedID { nsView.selectedID = selectedID }
    }
}

// MARK: - WaveformView

/// 波形 + 字幕リージョンバンド + プレイヘッドを描画する。
/// クリックで再生位置をシーク、字幕リージョンクリックで選択。
///
/// 成熟度: experimental
///
/// レイヤー構成 (描画順):
/// 1. 背景 (canvas color)
/// 2. 字幕リージョンバンド (SwiftUI overlay — Canvas 外で描画)
/// 3. 波形 (Canvas: 中央線から上下対称に縦線)
/// 4. プレイヘッド (SwiftUI overlay)
struct WaveformView: View {
    let waveform: WaveformData?
    let captionRegions: [CaptionRegion]
    let currentMs: Int
    let selectedRegionID: UUID?
    /// 波形未取得時のフォールバック (動画尺)。0 ならリージョン描画不可。
    var fallbackDurationMs: Int = 0
    let onSeek: (Int) -> Void
    let onSelectRegion: (UUID) -> Void

    static func intent() -> String {
        """
        役割: 波形 + 字幕リージョン + プレイヘッドを描画する。
              横軸 = 時刻 (0 → durationMs)、縦軸 = 振幅。
              リージョンとプレイヘッドは SwiftUI View として描画し、
              波形のみ Canvas で描画する。Canvas の再描画タイミングに
              依存しない設計。
        成熟度: experimental
        依存: WaveformData (peaks 配列), CaptionRegion (字幕区間)
        変更時の注意: peaks のサンプル数は表示幅と独立。
                     描画時に GeometryReader の width に合わせて間引き / 補間する。
        """
    }

    private var effectiveDurationMs: Int {
        waveform?.durationMs ?? fallbackDurationMs
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(EditorTheme.canvas)

                // 1. リージョンバンド (SwiftUI View — Canvas 外)
                regionBandOverlay(size: geo.size)

                // 2. 波形 (Canvas)
                Canvas { context, size in
                    drawWaveform(context: &context, size: size)
                }

                // 3. プレイヘッド (SwiftUI View — Canvas 外)
                playheadOverlay(size: geo.size)

                if waveform == nil {
                    overlayMessage("波形を抽出中…")
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        handleTap(at: value.location, in: geo.size)
                    }
            )
        }
    }

    // MARK: - Region band overlay (AppKit NSView)

    /// リージョンバンドを AppKit NSView で描画する。
    /// SwiftUI の Shape/Canvas ではデータ変化時のリフレッシュタイミングが
    /// 不安定で、リージョンが描画されないバグが起きていた。
    /// NSView.needsDisplay を didSet で明示的に発火する設計にした。
    private func regionBandOverlay(size: CGSize) -> some View {
        CaptionBandsView(
            regions: captionRegions,
            durationMs: effectiveDurationMs,
            selectedID: selectedRegionID
        )
    }

    // MARK: - Playhead overlay (SwiftUI)

    @ViewBuilder
    private func playheadOverlay(size: CGSize) -> some View {
        let durationMs = effectiveDurationMs
        if durationMs > 0 {
            let pxPerMs = size.width / CGFloat(durationMs)
            let x = CGFloat(currentMs) * pxPerMs

            Rectangle()
                .fill(Color.red)
                .frame(width: 1.5, height: size.height)
                .offset(x: x - size.width / 2)
        }
    }

    // MARK: - Waveform drawing (Canvas)

    private func drawWaveform(context: inout GraphicsContext, size: CGSize) {
        guard let waveform, !waveform.peaks.isEmpty else { return }

        let peaks = waveform.peaks
        let midY = size.height / 2
        let totalColumns = Int(size.width)
        guard totalColumns > 0 else { return }

        let progress = waveform.totalBinCount > 0
            ? Double(peaks.count) / Double(waveform.totalBinCount)
            : 1.0
        let drawColumns = max(1, Int(Double(totalColumns) * min(1.0, progress)))

        var path = Path()
        let peakCount = peaks.count

        for col in 0..<drawColumns {
            let amp: CGFloat
            if drawColumns >= peakCount && peakCount > 1 {
                let peakFloatIdx = Double(col) * Double(peakCount - 1) / Double(max(1, drawColumns - 1))
                let leftIdx = max(0, min(peakCount - 1, Int(peakFloatIdx)))
                let rightIdx = min(peakCount - 1, leftIdx + 1)
                let frac = peakFloatIdx - Double(leftIdx)
                let leftPeak = Double(peaks[leftIdx])
                let rightPeak = Double(peaks[rightIdx])
                let interpolated = Float(leftPeak * (1.0 - frac) + rightPeak * frac)
                amp = CGFloat(interpolated) * (size.height * 0.45)
            } else {
                let startIdx = (col * peakCount) / drawColumns
                let nextIdx  = ((col + 1) * peakCount) / drawColumns
                let endIdx   = max(startIdx + 1, nextIdx)
                let safeEnd  = min(endIdx, peakCount)
                guard startIdx < safeEnd else { continue }
                var localPeak: Float = 0
                for i in startIdx..<safeEnd {
                    if peaks[i] > localPeak { localPeak = peaks[i] }
                }
                amp = CGFloat(localPeak) * (size.height * 0.45)
            }

            let x = CGFloat(col) + 0.5
            path.move(to: CGPoint(x: x, y: midY - amp))
            path.addLine(to: CGPoint(x: x, y: midY + amp))
        }

        context.stroke(
            path,
            with: .color(.cyan.opacity(0.85)),
            lineWidth: 1
        )

        var midPath = Path()
        midPath.move(to: CGPoint(x: 0, y: midY))
        midPath.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(midPath, with: .color(.white.opacity(0.08)), lineWidth: 1)
    }

    private func overlayMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Interaction

    private func handleTap(at point: CGPoint, in size: CGSize) {
        let durationMs = effectiveDurationMs
        guard durationMs > 0 else { return }
        let ratio = max(0, min(1, point.x / size.width))
        let ms = Int(ratio * CGFloat(durationMs))

        if let hit = captionRegions.first(where: { ms >= $0.startMs && ms <= $0.endMs }) {
            onSelectRegion(hit.id)
            onSeek(hit.startMs)
        } else {
            onSeek(ms)
        }
    }
}
