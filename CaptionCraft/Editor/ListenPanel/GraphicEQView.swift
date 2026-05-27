import SwiftUI

/// 聴き直しパネル用 2 段階 EQ。
/// Stage 1: パラメトリック EQ (音声学ベース 6 バンド — 声の強調)
/// Stage 2: グラフィック EQ (10 バンド 1 オクターブ幅 — ノイズカット)
struct GraphicEQView: View {
    static func intent() -> String { """
    役割: 聴き直しパネルの 2 段階 EQ UI。
          Stage 1 = パラメトリック EQ (SII 準拠 6 バンド、声の強調)
          Stage 2 = グラフィック EQ (1 オクターブ 10 バンド、ノイズカット)
    成熟度: experimental
    依存: ListenEQProcessor (EQ ゲイン制御)
    """ }

    @ObservedObject var eqProcessor: ListenEQProcessor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stage 1: パラメトリック EQ
            parametricSection

            Divider().background(EditorTheme.divider)

            // Stage 2: グラフィック EQ
            graphicSection
        }
    }

    // MARK: - Stage 1: パラメトリック EQ

    private var parametricSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("パラメトリック EQ", systemImage: "waveform.path")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EditorTheme.textTertiary)

                Text("声の強調")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.6))

                Spacer()

                Button("リセット") {
                    eqProcessor.resetParametricEQ()
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
                .foregroundStyle(EditorTheme.textTertiary)
            }

            HStack(spacing: 0) {
                ForEach(eqProcessor.parametricBands) { band in
                    VStack(spacing: 2) {
                        Text(gainLabel(band.gain))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(
                                band.gain == 0 ? EditorTheme.textTertiary : .orange
                            )

                        VerticalEQSlider(
                            value: Binding(
                                get: { Double(band.gain) },
                                set: { eqProcessor.setParametricGain(Float($0), forBand: band.id) }
                            ),
                            range: -12...12,
                            isActive: band.gain != 0,
                            accentColor: .orange
                        )
                        .frame(width: 28, height: 80)

                        Text(band.label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(
                                band.gain == 0 ? EditorTheme.textSecondary : .orange
                            )

                        HStack(spacing: 4) {
                            ParametricKnob(
                                value: Binding(
                                    get: { band.frequency },
                                    set: { eqProcessor.setParametricFrequency($0, forBand: band.id) }
                                ),
                                range: frequencyRange(for: band),
                                logarithmic: true,
                                label: "F",
                                formatValue: formatFrequency,
                                accentColor: .orange
                            )

                            ParametricKnob(
                                value: Binding(
                                    get: { band.q },
                                    set: { eqProcessor.setParametricQ($0, forBand: band.id) }
                                ),
                                range: 0.3...8.0,
                                logarithmic: false,
                                label: "Q",
                                formatValue: { String(format: "%.1f", $0) },
                                accentColor: .cyan
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func frequencyRange(for band: ListenEQProcessor.EQBand) -> ClosedRange<Float> {
        switch band.id {
        case 0: return 20...200        // Sub
        case 1: return 100...600       // Body
        case 2: return 500...4000      // Presence
        case 3: return 2000...8000     // Clarity
        case 4: return 4000...12000    // Sibilance
        case 5: return 6000...20000    // Air
        default: return 20...20000
        }
    }

    // MARK: - Stage 2: グラフィック EQ

    private var graphicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("グラフィック EQ", systemImage: "slider.vertical.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EditorTheme.textTertiary)

                Text("ノイズカット")
                    .font(.system(size: 9))
                    .foregroundStyle(.cyan.opacity(0.6))

                Spacer()

                Button("リセット") {
                    eqProcessor.resetGraphicEQ()
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
                .foregroundStyle(EditorTheme.textTertiary)
            }

            HStack(spacing: 0) {
                ForEach(eqProcessor.graphicBands) { band in
                    VStack(spacing: 2) {
                        Text(gainLabel(band.gain))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(
                                band.gain == 0 ? EditorTheme.textTertiary : .cyan
                            )

                        VerticalEQSlider(
                            value: Binding(
                                get: { Double(band.gain) },
                                set: { eqProcessor.setGraphicGain(Float($0), forBand: band.id) }
                            ),
                            range: -12...12,
                            isActive: band.gain != 0,
                            accentColor: .cyan
                        )
                        .frame(width: 28, height: 70)

                        Text(band.label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(
                                band.gain == 0 ? EditorTheme.textSecondary : .cyan
                            )

                        Text(band.detail)
                            .font(.system(size: 7))
                            .foregroundStyle(EditorTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func gainLabel(_ gain: Float) -> String {
        if gain == 0 { return "0" }
        return String(format: "%+.0f", gain)
    }

    private func formatFrequency(_ f: Float) -> String {
        if f >= 1000 {
            let k = f / 1000
            return k == floorf(k) ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
        } else {
            return String(format: "%.0f", f)
        }
    }
}

// MARK: - カスタム縦スライダー

struct VerticalEQSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var isActive: Bool = false
    var accentColor: Color = .orange

    private let trackWidth: CGFloat = 3
    private let thumbSize: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height - thumbSize
            let centerY = height / 2
            let ratio = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbY = (1.0 - ratio) * height

            ZStack {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: trackWidth, height: geo.size.height)

                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 10, height: 1)
                    .offset(y: centerY - geo.size.height / 2 + thumbSize / 2)

                if isActive {
                    let zeroY = centerY
                    let fillTop = min(thumbY, zeroY)
                    let fillHeight = abs(thumbY - zeroY)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accentColor.opacity(0.6))
                        .frame(width: trackWidth, height: fillHeight)
                        .offset(y: fillTop + fillHeight / 2 - geo.size.height / 2 + thumbSize / 2)
                }

                Circle()
                    .fill(isActive ? accentColor : Color.gray)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(y: thumbY - geo.size.height / 2 + thumbSize / 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let y = drag.location.y - thumbSize / 2
                        let clamped = max(0, min(height, y))
                        let ratio = 1.0 - clamped / height
                        value = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
}

// MARK: - パラメトリック EQ ノブ

/// 回転ノブでパラメータを変更する汎用コンポーネント。
/// 上ドラッグで時計回り (値上昇)、下ドラッグで反時計回り (値下降)。
private struct ParametricKnob: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var logarithmic: Bool = false
    var label: String = ""
    var formatValue: (Float) -> String = { String(format: "%.1f", $0) }
    var accentColor: Color = .orange

    @State private var dragStartValue: Float = 0

    private let knobSize: CGFloat = 22
    private let minAngle: Double = -135
    private let maxAngle: Double = 135

    private var normalizedValue: Double {
        if logarithmic {
            let logMin = log2(Double(range.lowerBound))
            let logMax = log2(Double(range.upperBound))
            let logVal = log2(Double(value))
            return (logVal - logMin) / (logMax - logMin)
        } else {
            return Double(value - range.lowerBound) / Double(range.upperBound - range.lowerBound)
        }
    }

    private var rotationAngle: Double {
        minAngle + normalizedValue * (maxAngle - minAngle)
    }

    var body: some View {
        VStack(spacing: 1) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(accentColor.opacity(0.5))
            }

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.2), Color.white.opacity(0.05)],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: knobSize / 2
                        )
                    )
                    .frame(width: knobSize, height: knobSize)

                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    .frame(width: knobSize, height: knobSize)

                Rectangle()
                    .fill(accentColor)
                    .frame(width: 2, height: knobSize / 2 - 2)
                    .offset(y: -(knobSize / 4 - 1))
                    .rotationEffect(.degrees(rotationAngle))
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if dragStartValue == 0 { dragStartValue = value }
                        if logarithmic {
                            let logMin = log2(Double(range.lowerBound))
                            let logMax = log2(Double(range.upperBound))
                            let logRange = logMax - logMin
                            let delta = Double(-drag.translation.height) / 150.0 * logRange
                            let logStart = log2(Double(dragStartValue))
                            let newLog = max(logMin, min(logMax, logStart + delta))
                            value = Float(pow(2.0, newLog))
                        } else {
                            let linRange = Double(range.upperBound - range.lowerBound)
                            let delta = Float(-drag.translation.height) / 150.0 * Float(linRange)
                            value = max(range.lowerBound, min(range.upperBound, dragStartValue + delta))
                        }
                    }
                    .onEnded { _ in
                        dragStartValue = 0
                    }
            )

            Text(formatValue(value))
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(accentColor.opacity(0.7))
        }
    }
}
