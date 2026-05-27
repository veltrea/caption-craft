import SwiftUI

// MARK: - View.e2eTrack(id:role:label:)
//
// CC Phase 02 で旧プロジェクトの Debug/E2E ディレクトリを全削除した際、E2E
// テスト要素トラッキング用 modifier `e2eTrack(id:role:label:)` が定義ごと消えた。
// しかし `e2eTrack` 呼び出しは Editor / RightPanel / PreviewArea / Caption など
// UI コード全体に散らばっており、すべてを削るのは Phase 02 のスコープを大きく
// 超える。
//
// そこで本ファイルでは、accessibilityIdentifier だけは付ける軽量 stub を提供し、
// 既存の呼び出し箇所をそのまま残してビルドを通す。Registry 登録機能は CC Phase 03
// で E2E 基盤を再構成するときに改めて実装する。
//
// 削除タイミング: CC Phase 03 (Debug/E2E 再構成) で本ファイルを削除し、
// 新しい E2E 基盤に合わせた modifier を別の場所に定義する予定。

extension View {

    /// E2E トラッキング用 modifier の軽量 stub。`accessibilityIdentifier(id)` だけ
    /// 付与する。CC Phase 03 で Registry 機能を含む完全実装に置き換える予定。
    ///
    /// - Parameters:
    ///   - id: ユニーク ID。命名規則は CC Phase 03 で再策定予定 (旧プロジェクトの
    ///     例: `editor.rightPanel.caption.modelPicker`)。
    ///   - role: AX ロール文字列。本 stub では未使用。
    ///   - label: UI ラベル。本 stub では未使用。
    func e2eTrack(
        id: String,
        role: String = "AXButton",
        label: String? = nil
    ) -> some View {
        accessibilityIdentifier(id)
    }
}
