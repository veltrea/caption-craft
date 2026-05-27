import Combine
import CoreMedia
import Foundation
import SwiftUI

/// タイムライン上で表示する字幕を扱う ViewModel。
///
/// CC Phase 03 で動画編集系 (Zoom/Trim/Speed/Annotation/TTS/BGM/Narration/Keystroke/
/// MouseEvent) の helpers と、Clipboard / TimelineItem の概念を全削除した結果、
/// 本クラスは「再生位置と紐付く Caption の選択 / 編集 / 削除」だけを扱う最小構成に
/// なっている。
///
/// 残置された `pixelsPerSecond` は将来 (CC Phase 04 で再構成する) Caption タイムライン
/// 横スクロール UI のスケール変換に使う。現状は最小スケール固定でも動く。
@MainActor
final class TimelineViewModel: ObservableObject {
    @Published var pixelsPerSecond: Double = 100
    @Published var selectedItemID: UUID? = nil

    // MARK: - Zoom-level bounds

    static let minPixelsPerSecond: Double = 10
    static let maxPixelsPerSecond: Double = 400

    // MARK: - Scale helpers

    func xOffset(forMs ms: Int) -> CGFloat {
        CGFloat(Double(ms) / 1000.0 * pixelsPerSecond)
    }

    func width(fromMs startMs: Int, toMs endMs: Int) -> CGFloat {
        CGFloat(Double(max(0, endMs - startMs)) / 1000.0 * pixelsPerSecond)
    }

    func ms(forX x: CGFloat) -> Int {
        Int((Double(x) / pixelsPerSecond) * 1000)
    }

    // MARK: - Selection helpers

    func selectedCaptionRegion(in state: EditorState) -> CaptionRegion? {
        guard let id = selectedItemID else { return nil }
        return state.captionRegions.first { $0.id == id }
    }

    func select(itemID: UUID) {
        selectedItemID = itemID
    }

    func deselect() {
        selectedItemID = nil
    }

    // MARK: - Caption add / live update / commit / lookup / delete

    /// 現在時刻に空の `CaptionRegion` を挿入する。
    /// デフォルト長さは 3 秒。空文字 + `isManuallyEdited = true` で作成し、
    /// ユーザーが後からテキストを書き込む前提 (自動合成時に保護される)。
    @discardableResult
    func addCaption(atMs currentMs: Int, store: ProjectStore) -> UUID? {
        guard var state = store.project?.editor else { return nil }
        let start = max(0, currentMs)
        var region = CaptionRegion(startMs: start, endMs: start + 3000)
        region.isManuallyEdited = true
        region.sourceLanguage = state.captionSettings.language
        state.captionRegions.append(region)
        store.commitState(state)
        selectedItemID = region.id
        return region.id
    }

    /// `CaptionRegion` のプロパティを live-update する (undo 対象外)。
    /// `TextEditor` の編集中などに使う。
    func updateCaption(_ region: CaptionRegion, store: ProjectStore) {
        guard var state = store.project?.editor else { return }
        guard let idx = state.captionRegions.firstIndex(where: { $0.id == region.id }) else { return }
        state.captionRegions[idx] = region
        store.updateState(state)
    }

    /// `CaptionRegion` の更新を確定する (undo 対象)。
    /// `TextEditor` の blur や時刻入力の確定タイミングで呼ぶ。
    func commitCaption(_ region: CaptionRegion, store: ProjectStore) {
        guard var state = store.project?.editor else { return }
        guard let idx = state.captionRegions.firstIndex(where: { $0.id == region.id }) else { return }
        state.captionRegions[idx] = region
        store.commitState(state)
    }

    /// 現在時刻に対応する `CaptionRegion` を返す (オーバーレイ表示用)。
    /// 複数 overlap する場合は最初に見つかったものを返す。
    func captionAt(ms: Int, in state: EditorState) -> CaptionRegion? {
        state.captionRegions.first { $0.startMs <= ms && ms < $0.endMs }
    }

    /// 指定 `id` の Caption を削除する。
    func delete(regionID: UUID, store: ProjectStore) {
        guard var state = store.project?.editor else { return }
        state.captionRegions.removeAll { $0.id == regionID }
        if selectedItemID == regionID {
            selectedItemID = nil
        }
        store.commitState(state)
    }
}
