import SwiftUI

// MARK: - CaptionOverlayView

/// プレビュー下部に重ねる字幕オーバーレイ。
/// 現在再生位置に対応する CaptionRegion を 1 つだけ表示する。
///
/// 成熟度: experimental (FIX_10 Phase 1)
///
/// Phase 1 非対応:
/// - 2 行折り返し: docs/DESIGN.md のタイポに従い 1 行 + `lineLimit(2)` で切る
/// - カラオケ風 word highlight: 日本語で無意味なため永久 non-goal
/// - 位置カスタマイズ: 将来対応
struct CaptionOverlayView: View {
    @ObservedObject var store:    ProjectStore
    @ObservedObject var playback: PlaybackController
    @ObservedObject var timeline: TimelineViewModel

    var body: some View {
        if let region = visibleRegion, !region.text.isEmpty {
            VStack {
                Spacer()
                VStack(spacing: 2) {
                    Text(region.text)
                        .font(.system(size: 18, weight: .medium, design: .default))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let translated = region.translatedText, !translated.isEmpty {
                        Text(translated)
                            .font(.system(size: 15, weight: .regular, design: .default))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.6))
                )
                .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Derived

    private var currentMs: Int {
        let s = playback.currentTime.seconds
        return s.isFinite ? max(0, Int(s * 1000)) : 0
    }

    private var visibleRegion: CaptionRegion? {
        guard let state = store.project?.editor else { return nil }
        return timeline.captionAt(ms: currentMs, in: state)
    }
}
