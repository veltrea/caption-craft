import Foundation

// MARK: - TimelineRegion

/// タイムライン上に描画される区間の共通プロトコル。
///
/// CC Phase 03 で動画編集系の Region 型 (Zoom / Trim / Speed / Annotation / TTS / BGM /
/// Narration / Keystroke / MouseEvent) を全削除した結果、現状で本プロトコルに
/// conform するのは `CaptionRegion` のみ。
///
/// 残置理由: 将来 SubtitleFormatKit / SubtitleAgentKit 等を SPM に切り出す際の
/// 抽象化ポイントとして温存する (たとえば「字幕 + 補助マーカー (章区切り等)」を
/// 同じ TimelineRegion 系で扱う可能性)。
protocol TimelineRegion: Identifiable where ID == UUID {
    var id: UUID { get }
    var startMs: Int { get set }
    var endMs: Int { get set }
}
