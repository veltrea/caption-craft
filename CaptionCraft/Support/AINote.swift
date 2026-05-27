import Foundation

/// AI セッション (Claude など) に読ませたいローカルなガイダンスを、
/// 実行時は no-op な関数呼び出しとして書き残すためのマーカー。
///
/// 背景:
/// intent() 関数アーキテクチャ (FIX_07) はクラス/構造体レベルの meta
/// 記述。それでもカバーしきれない「関数内の 1 行や分岐、特定ロジック」
/// に AI 向けの注記を残したいケースがある。
///
/// コメント (`//` や `///`) は AI セッションが読み飛ばす傾向が
/// 計測で確認されている。一方、関数呼び出しはコードとして必ず解析
/// されるため、コメントより確実に文脈を伝えられる。
///
/// 使える場所:
/// ```swift
/// // 通常の関数本体
/// func setupPanel() {
///     aiNote("ここは順序依存。X を先に初期化してから Y。")
///     initializeX()
///     initializeY()
/// }
///
/// // init / onAppear / task / Button action などのクロージャ内
/// Button("Save") {
///     aiNote("保存前に dirty flag を上げる (undo 履歴との整合のため)")
///     markDirty()
///     save()
/// }
///
/// // @State / @ObservedObject 宣言の近く (直前の空行で呼ぶのは NG、
/// // init 内で呼ぶ)
/// init() {
///     aiNote("SomeState のデフォルトは nil。load() 完了後に確定する")
/// }
/// ```
///
/// 使ってはいけない場所 (重要):
/// **SwiftUI の `body` / `ViewBuilder` の中では呼ばない。**
/// aiNote は Void を返すため ViewBuilder が View でないと怒る。
/// さらに EmptyView を返す設計にすると ViewBuilder の layout 解釈に
/// 影響して hit test 異常など予期しないバグを引き起こすことが確認
/// されている (2026-04-20 UI 全停止事故)。
///
/// body 内の View 階層に対して AI 向けガイダンスを残したい場合は:
/// - クラス全体に関わる話なら `static func intent()` に書く
/// - ローカルな話なら `var body` の直前に `///` のコメントで書く
///   (このケースは目立つので AI も読む)
/// - View を切り出した private func に `aiNote` 入り本文を書く
///
/// 検索:
/// プロジェクト内の AI ガイダンス一覧抽出:
/// ```
/// grep -rn 'aiNote(' CaptionCraft/
/// ```
///
/// 実行時コスト:
/// `@inline(__always)` + 空 body で実質ゼロ。Release では最適化で
/// 文字列リテラルごと消える前提。
@inline(__always)
func aiNote(_ message: String) {
    _ = message
}
