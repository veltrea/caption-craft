import SwiftUI

// docs/DESIGN.md のセクション 7.4 で定めたカラーパレット。
// デザインシステム名は「The Obsidian Lens」（黒曜石のレンズ）。
// 接頭辞 "sc" は SwiftUI 標準の Color と区別するためのプロジェクト固有プレフィックス。
extension Color {
    // 背景の黒系（深い → 明るい）
    static let scSurface                  = Color(hex: "#131313")
    static let scSurfaceContainerLow      = Color(hex: "#1B1C1C")
    static let scSurfaceContainer         = Color(hex: "#1F2020")
    static let scSurfaceContainerHigh     = Color(hex: "#2A2A2A")
    static let scSurfaceContainerHighest  = Color(hex: "#353535")

    // ブランドカラー（淡い水色、ダークモード上での読みやすさ用）
    static let scPrimary                  = Color(hex: "#ADC6FF")

    // 選択バッジや録画中インジケーター等、強い強調が必要なときの青
    // macOS のシステムアクセントブルーと同じ値
    static let scPrimaryAccent            = Color(hex: "#007AFF")

    // 背景上に乗せる文字色のデフォルト
    static let scOnSurface                = Color(hex: "#E4E2E1")

    // ガラス表面のうっすらした縁取りに使うグレー
    static let scOutlineVariant           = Color(hex: "#414755")
}
