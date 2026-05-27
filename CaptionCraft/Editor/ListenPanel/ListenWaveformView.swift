import AudioCommon
import AVFoundation
import SwiftUI

/// 聴き直しパネル用の波形表示。ループ区間の PCM から高解像度 peaks を計算して描画する。
struct ListenWaveformView: View {
    static func intent() -> String { """
    役割: ループ区間の波形を描画し、プレイヘッド・スライスマーカーを表示。
          Option+クリックでスライス追加、スライスマーカーのドラッグ移動に対応。
    成熟度: experimental
    依存: PlaybackController.loopProgress (0〜1 の再生進捗)
    変更時の注意: プレイヘッド位置は PlaybackController が composition 時間から
                 直接計算した loopProgress を使う。ビュー側で ms 変換しない。
    """ }

    let sourceURL: URL?
    let loopStartMs: Int
    let loopEndMs: Int

    let progress: Double
    let onSeekRatio: (Double) -> Void

    @Binding var slicePoints: [SliceDetector.SlicePoint]

    @State private var peaks: [Float] = []
    @State private var _lastCanvasSize: CGSize?

    /// ドラッグ中のスライスインデックス (-1 = ドラッグなし)
    @State private var draggingSliceIndex: Int = -1

    private var loopDurationMs: Int { max(1, loopEndMs - loopStartMs) }

    /// スライスマーカーの当たり判定の幅 (px)
    private let sliceHitWidth: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            drawBackground(context: &context, size: size)
            drawWaveform(context: &context, size: size)
            drawSliceMarkers(context: &context, size: size)
            drawPlayhead(context: &context, size: size)
        }
        .contentShape(Rectangle())
        .gesture(waveformGesture)
        .overlay(GeometryReader { geo in
            Color.clear.onAppear { _lastCanvasSize = geo.size }
                .onChange(of: geo.size) { _lastCanvasSize = $0 }
        })
        .frame(height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(sourceURL?.path ?? "")_\(loopStartMs)_\(loopEndMs)") {
            await loadPeaks()
        }
    }

    // MARK: - ジェスチャー

    private var waveformGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let size = _lastCanvasSize, size.width > 0 else { return }

                if draggingSliceIndex >= 0 {
                    // ドラッグ中: スライス位置を更新
                    let ratio = max(0, min(1, Double(value.location.x / size.width)))
                    let ms = loopStartMs + Int(ratio * Double(loopDurationMs))
                    let clamped = max(loopStartMs + 10, min(loopEndMs - 10, ms))
                    slicePoints[draggingSliceIndex].ms = clamped
                    return
                }

                // ドラッグ開始: 近くのスライスマーカーを探す
                let hitIndex = findSliceAtX(value.startLocation.x, in: size)
                if hitIndex >= 0 {
                    draggingSliceIndex = hitIndex
                    let ratio = max(0, min(1, Double(value.location.x / size.width)))
                    let ms = loopStartMs + Int(ratio * Double(loopDurationMs))
                    let clamped = max(loopStartMs + 10, min(loopEndMs - 10, ms))
                    slicePoints[draggingSliceIndex].ms = clamped
                }
            }
            .onEnded { value in
                if draggingSliceIndex >= 0 {
                    // ドラッグ完了: ソートし直す
                    draggingSliceIndex = -1
                    slicePoints.sort { $0.ms < $1.ms }
                    return
                }

                guard let size = _lastCanvasSize, size.width > 0 else { return }

                // Option+クリック: スライス追加
                if NSEvent.modifierFlags.contains(.option) {
                    let ratio = max(0, min(1, Double(value.location.x / size.width)))
                    let ms = loopStartMs + Int(ratio * Double(loopDurationMs))
                    let clamped = max(loopStartMs, min(loopEndMs, ms))
                    let newPoint = SliceDetector.SlicePoint(ms: clamped, kind: .manual)
                    slicePoints.append(newPoint)
                    slicePoints.sort { $0.ms < $1.ms }
                    return
                }

                // 通常クリック: シーク
                let ratio = max(0, min(1, Double(value.location.x / size.width)))
                onSeekRatio(ratio)
            }
    }

    /// x 座標の近くにあるスライスマーカーのインデックスを返す。なければ -1。
    private func findSliceAtX(_ x: CGFloat, in size: CGSize) -> Int {
        for (i, point) in slicePoints.enumerated() {
            let ratio = CGFloat(point.ms - loopStartMs) / CGFloat(loopDurationMs)
            let sliceX = ratio * size.width
            if abs(x - sliceX) <= sliceHitWidth {
                return i
            }
        }
        return -1
    }

    // MARK: - PCM → peaks

    private func loadPeaks() async {
        guard let url = sourceURL else { return }
        let start = loopStartMs
        let end = loopEndMs
        guard end > start else { return }

        let result = await Task.detached(priority: .userInitiated) { () -> [Float] in
            do {
                let samples = try AudioFileLoader.load(url: url, targetSampleRate: 16_000)
                let startSample = max(0, start * 16_000 / 1000)
                let endSample = min(samples.count, end * 16_000 / 1000)
                guard endSample > startSample else { return [] }

                let region = Array(samples[startSample..<endSample])
                return Self.downsample(region, to: 800)
            } catch {
                return []
            }
        }.value

        await MainActor.run { peaks = result }
    }

    // MARK: - Canvas 描画

    private func drawBackground(context: inout GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(EditorTheme.canvas))
    }

    private func drawWaveform(context: inout GraphicsContext, size: CGSize) {
        guard !peaks.isEmpty else { return }
        let midY = size.height / 2
        let totalColumns = Int(size.width)
        guard totalColumns > 0 else { return }

        var path = Path()
        for col in 0..<totalColumns {
            let fi = Double(col) / Double(totalColumns) * Double(peaks.count)
            let idx0 = Int(fi)
            let frac = Float(fi - Double(idx0))
            let p0 = peaks[min(idx0, peaks.count - 1)]
            let p1 = peaks[min(idx0 + 1, peaks.count - 1)]
            let amp = CGFloat(p0 + (p1 - p0) * frac)
            let h = max(1, amp * midY * 0.9)
            path.move(to: CGPoint(x: CGFloat(col), y: midY - h))
            path.addLine(to: CGPoint(x: CGFloat(col), y: midY + h))
        }
        context.stroke(path, with: .color(EditorTheme.waveform.opacity(0.7)), lineWidth: 1)
    }

    private func drawSliceMarkers(context: inout GraphicsContext, size: CGSize) {
        guard loopDurationMs > 0 else { return }
        for (index, point) in slicePoints.enumerated() {
            let ratio = CGFloat(point.ms - loopStartMs) / CGFloat(loopDurationMs)
            let x = ratio * size.width
            guard x >= 0, x <= size.width else { continue }

            let isDragging = index == draggingSliceIndex
            let color: Color = {
                switch point.kind {
                case .silence: return .cyan.opacity(isDragging ? 1.0 : 0.6)
                case .regionBoundary: return .yellow.opacity(isDragging ? 1.0 : 0.7)
                case .manual: return .green.opacity(isDragging ? 1.0 : 0.7)
                }
            }()

            var linePath = Path()
            linePath.move(to: CGPoint(x: x, y: 0))
            linePath.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(linePath, with: .color(color),
                          style: StrokeStyle(lineWidth: isDragging ? 2 : 1, dash: [3, 3]))

            // 上部に三角マーカー
            var tri = Path()
            tri.move(to: CGPoint(x: x - 4, y: 0))
            tri.addLine(to: CGPoint(x: x + 4, y: 0))
            tri.addLine(to: CGPoint(x: x, y: 6))
            tri.closeSubpath()
            context.fill(tri, with: .color(color))

            // キー番号ラベル (1〜9)
            if index < 9 {
                let label = Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                context.draw(label, at: CGPoint(x: x, y: size.height - 10))
            }
        }
    }

    private func drawPlayhead(context: inout GraphicsContext, size: CGSize) {
        let clamped = max(0, min(1, progress))
        let x = clamped * size.width

        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(.red), lineWidth: 1.5)
    }

    // MARK: - Private

    private nonisolated static func downsample(_ samples: [Float], to binCount: Int) -> [Float] {
        guard !samples.isEmpty, binCount > 0 else { return [] }
        var result = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let start = i * samples.count / binCount
            let end = min(samples.count, (i + 1) * samples.count / binCount)
            var maxAbs: Float = 0
            for j in start..<end {
                let v = abs(samples[j])
                if v > maxAbs { maxAbs = v }
            }
            result[i] = maxAbs
        }
        let globalMax = result.max() ?? 1.0
        if globalMax > 0 {
            for i in 0..<result.count { result[i] /= globalMax }
        }
        return result
    }
}
