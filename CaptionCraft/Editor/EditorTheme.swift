import SwiftUI

/// Editor 画面の配色トークン (ScreenStudio ライクなダーク UI)。
enum EditorTheme {

    static func intent() -> String {
        return """
        役割: Editor ウィンドウ全体の配色トークン。Chrome (トップバー/右パネル/
              トランスポート/タイムライン) の背景・前景・アクセントを一箇所に集約する。

        成熟度: experimental
        → Editor UI の ScreenStudio 風リデザイン (2026-04-20) に合わせて新設。
          配色は View からは必ず EditorTheme.xxx 経由で参照すること。

        触ってはいけない:
        - "accent" は purple (#7C5CFF 系)。プライマリ CTA に使用。
          ブランド変更時は全箇所を一気に差し替える想定なので直書きしない。

        変更時の注意:
        - 新しい View を追加する時は controlBackgroundColor / windowBackgroundColor
          を直接使わず、ここの EditorTheme.panel / EditorTheme.chrome を使う。
        """
    }

    // MARK: - Surfaces

    /// ウィンドウ最背面 (タイトルバー〜ツールバー背景)
    static let chrome       = rgb(0x0D, 0x0D, 0x10)

    /// プレビュー背景 (中央の広い領域)
    static let canvas       = rgb(0x17, 0x17, 0x1B)

    /// 右パネル / アイコンレール背景
    static let panel        = rgb(0x13, 0x13, 0x18)

    /// タイムライン背景
    static let timeline     = rgb(0x0A, 0x0A, 0x0D)

    /// 押下時 / セグメント選択時のハイライト
    static let surfaceHi    = rgb(0x26, 0x26, 0x2E)

    /// 罫線
    static let divider      = Color.white.opacity(0.06)

    // MARK: - Text

    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary  = Color.white.opacity(0.38)

    // MARK: - Accents

    /// プライマリ CTA (選択中セグメント)
    static let accent        = rgb(0x7C, 0x5C, 0xFF)

    /// タイムラインクリップ
    static let clipFill      = rgb(0x6D, 0x57, 0xFF)
    static let clipStroke    = rgb(0x9B, 0x88, 0xFF)

    /// オーディオ波形
    static let waveform      = rgb(0xF5, 0xA6, 0x23)

    // MARK: - Helpers

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(.sRGB,
              red:   Double(r) / 255,
              green: Double(g) / 255,
              blue:  Double(b) / 255,
              opacity: 1)
    }
}
