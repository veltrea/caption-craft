# CaptionCraft — Design System

> 本書は CaptionCraft の **デザインシステム専用ドキュメント**です (ソフトウェアの設計仕様・技術ドキュメントは `SPEC.md` / `ARCHITECTURE.md` 等に置く)。
> 原典は Stitch (Google) で生成された `design_md` (プロジェクト `11952110867404552482` "Screen Source Selector Grid"、2026-04-19)。macOS / SwiftUI 特化の補足を §7 に追加しています。

---

## 1. Overview & Creative North Star

**Creative North Star: "The Obsidian Lens"**

This design system is built to bridge the gap between functional utility and high-end desktop aesthetics. Rather than feeling like a "web app" ported to the desktop, this system leans into the "Obsidian Lens" philosophy: UI elements should feel like precision-cut glass floating over the user's workspace.

The system prioritizes **Atmospheric Depth**. By utilizing high-refraction backdrop blurs and a strict hierarchy of translucent layers, we create a sense of focused calm. We break the "template" look by eschewing heavy structural lines in favor of tonal shifts and intentional negative space, ensuring the screen recording popover feels like a native, premium extension of the macOS ecosystem.

> 要約: 「精密研磨したガラスがユーザーのワークスペースに浮かんでいる」ような UI を目指す。Web アプリを移植した感じではなく、macOS ネイティブの延長線として振る舞うこと。線で区切るのではなく、色調の変化 (tonal shift) と余白でヒエラルキーを作る。

---

## 2. Colors & Surface Logic

### Tonal Palette

The palette is rooted in deep neutrals, using `surface` tokens to define light transmission rather than just pigment.

- **Primary (Accent):** `primary` (`#adc6ff` / `#007AFF`) — Reserved strictly for active states, primary actions, and the signature 20x20px checkmark badge
- **Surface:** `surface` (`#131313`) — The base layer
- **Popover Base:** `rgba(36, 36, 36, 0.92)` — Our signature "Glass" surface

### The "No-Line" Rule

Sectioning must **never** be achieved with solid 1px borders. Instead, boundaries are defined by:

1. **Background Shifts:** Use `surface-container-low` for the main body and `surface-container-high` for interactive cards
2. **Luminous Edges:** A "Ghost Border" of 1px white-alpha (e.g., `outline-variant` at 10〜15% opacity) is permitted only to define the outer silhouette of the popover against the desktop background

### Surface Hierarchy & Nesting

Treat the UI as a physical stack of glass:

- **Level 0 (Desktop):** The user's wallpaper
- **Level 1 (Main Popover):** `surface` with 0.92 opacity + 20px backdrop blur
- **Level 2 (Internal Cards):** `surface-container-highest` (10px radius) to create a "lifted" interactive zone

### Full Color Tokens

```
background               #131313
surface                  #131313
surface-dim              #131313
surface-container-lowest #0e0e0e
surface-container-low    #1b1c1c
surface-container        #1f2020
surface-container-high   #2a2a2a
surface-container-highest #353535
surface-bright           #393939
surface-variant          #353535

primary                  #adc6ff   (dark mode token; WCAG-safe on deep surface)
primary-container        #4b8eff
primary-fixed            #d8e2ff
on-primary               #002e69
on-primary-container     #00285c

secondary                #adc6ff
secondary-container      #26467d

tertiary                 #ffb595
tertiary-container       #ef6719

error                    #ffb4ab
error-container          #93000a
on-error                 #690005

outline                  #8b90a0
outline-variant          #414755   (Ghost border @ 10〜15% opacity)

on-surface               #e4e2e1
on-surface-variant       #c1c6d7
on-background            #e4e2e1
```

**Macアクセント互換色**: `#007AFF` (macOS system blue)。ハイコントラスト用途 (selection badge、active state ring) で使用。

---

## 3. Typography: The Editorial Scale

CaptionCraft uses a tight, sophisticated typography scale to mimic the density of professional desktop software. The primary typeface is **Inter** in Stitch mockups (chosen as a high-fidelity alternative to SF Pro), but in macOS production code we use **SF Pro** (system default) — see §7.

| Token | Size | Opacity | Role |
|---|---|---|---|
| **Title-SM** | 13pt (1rem) | 95% | Section headers and modal titles |
| **Label-MD** | 12pt (0.75rem) | 90% | Action labels and button text |
| **Label-SM** | 11pt (0.68rem) | 55% | Captions, metadata, and secondary hints |

**Editorial Note:** Use `title-sm` for primary labels within cards, and `label-sm` for status indicators. The 40% difference in opacity between titles and captions creates hierarchy without requiring font-weight bloating.

> 要約: ウェイトで強調するのではなく、**透明度 (opacity) で階層を作る**。95% → 90% → 55% の 3 段階。これが「editorial」な品のある情報密度を生む。

---

## 4. Elevation & Depth

### The Layering Principle

Depth is achieved through **Tonal Layering**. To highlight a specific recording source (e.g., "Display 1"), do not use a stroke. Instead, place a `primary-container` background behind the selection with a subtle `on-primary-container` text color.

### Ambient Shadows

For the main popover, use a "Wide-Spectrum" shadow:

- **Shadow:** `0 20px 40px rgba(0, 0, 0, 0.4)`
- **Tint:** Ensure the shadow has a 2% hint of the `primary` blue to simulate the light of the screen interacting with the glass surface

### Glassmorphism & Depth

Every container must feel "luminous." Apply a `backdrop-filter: blur(25px)` to the main popover. This ensures that as the user moves the popover across different windows, the UI "absorbs" the colors of the background, making it feel integrated into the OS.

> 要約: 枠線ではなく **ガラス越しの光** が深さを作る。影には青を 2% だけ混ぜて「画面の光がガラスに反射している感」を出す。濁った黒影は禁止。

---

## 5. Components

### The Popover (Main Container)

- **Radius:** 12px (`md` in scale)
- **Border:** 1px `outline-variant` at 15% opacity (The "Ghost Border")
- **Padding:** 16px internal gutter to allow elements to breathe

### Interactive Cards (Selection Items)

- **Radius:** 10px
- **Background:** `surface-container-high`
- **Interaction:** On hover, transition to `surface-container-highest`. On select, apply the `primary` checkmark badge
- **Note:** No dividers. Use 8px of vertical whitespace to separate items

### Selection Badge

- **Size:** 20x20px
- **Color:** `primary` (`#007AFF` when rendered against dark surfaces)
- **Icon:** White 1.5px weight checkmark, centered

### Buttons

- **Primary:** High-contrast `primary` background with `on-primary` text. 8px corner radius
- **Secondary (Ghost):** No background. Use `label-md` typography. On hover, a subtle `surface-variant` background at 30% opacity fades in

### List Rows (Compact List Layout — 2026-04-20 採用)

採用案 C の項目行 (`SourceSelectorView` で使用):

- **Height:** 44px (ディスプレイ / ウィンドウ両方で統一)
- **Padding:** 14px horizontal, 0 vertical
- **Leading Icon:** 22x22px (SF Symbol)
- **Gap Icon → Label:** 12px
- **Label:** `title-sm` (13pt, 95% opacity), 1 line truncate
- **Trailing Selection Indicator:** 20x20 slot reserved. If selected, show `primary` filled circle + white check
- **Selected Row Background:** `rgba(0,122,255,0.16)` (`primary` at 16% alpha)
- **Hover:** Row background `rgba(255,255,255,0.05)` fade-in 200ms

---

## 6. Do's and Don'ts

### Do

- **Use Asymmetry:** Place controls like "Settings" or "Close" in intentional, non-centered positions to provide a bespoke feel
- **Embrace Transparency:** Ensure the `surface` tokens are always slightly translucent when used in floating windows
- **Subtle Transitions:** All hover states should have a 200ms ease-out transition

### Don't

- **Don't use pure black (`#000`):** It kills the "Glass" effect. Use the `surface` (`#131313`) or the rgba value provided
- **Don't use dividers:** If a list feels cluttered, increase the `spacing` scale rather than adding a line
- **Don't use heavy shadows:** If you can "see" the shadow clearly, it's too dark. It should be felt, not seen

---

## 7. macOS / SwiftUI 特化の補足 (CaptionCraft 固有)

Stitch mockups は Web (HTML + Tailwind) 前提で書かれているため、macOS ネイティブアプリに落とす際は以下の読み替えを徹底する。

### 7.1 フォントは SF Pro (Inter ではない)

- Stitch の HTML: `font-family: 'Inter'`
- SwiftUI: **システムフォントをそのまま使う**。`.font(.system(size: 13, weight: .medium))` などで呼ぶ。Inter は Web での近似、SF Pro は macOS の純正で、メトリックもほぼ同じ
- `.fontDesign(.default)` は触らない (SF Pro が default)

### 7.2 アイコンは SF Symbols (Material Symbols ではない)

Stitch HTML は `Material Symbols Outlined` を使うが、CaptionCraft は **SF Symbols** を使う:

| 用途 | Material Symbols | SF Symbols |
|---|---|---|
| ディスプレイ | `monitor` | `display` |
| 独立モニタ | `desktop_mac` | `display.2` |
| ディスプレイ汎用 | `desktop_windows` | `rectangle.inset.filled` / `display` |
| ウィンドウ | `web_asset` / `crop_square` | `macwindow` |
| ブラウザ | `public` / `explore` | `safari` (Safari) / `globe` (汎用) |
| ターミナル | `terminal` | `terminal` (iOS 17+ は同名で SF Symbols にある) |
| コード | `code` / `code_blocks` | `chevron.left.forwardslash.chevron.right` |
| フォルダ | `folder` / `folder_open` | `folder` / `folder.fill` |
| メモ | `description` / `edit_document` | `note.text` / `note` |
| メッセージ | `chat` | `message.fill` |
| メール | `mail` | `envelope.fill` |
| 音楽 | `music_note` | `music.note` |
| チェック | `check` | `checkmark` |
| 閉じる | `close` | `xmark` |
| 設定 | `settings` | `gearshape` |

取得できないアプリアイコン (動的、未知のアプリ) は `macwindow` を既定フォールバックに使う。

### 7.3 Glass surface は `.regularMaterial`

- Web: `backdrop-filter: blur(25px)` + `background: rgba(36,36,36,0.92)`
- SwiftUI (macOS): **`.background(.regularMaterial)` を使う** — OS が管理する本物のガウシアン blur。`.ultraThinMaterial` / `.thinMaterial` / `.regularMaterial` / `.thickMaterial` / `.ultraThickMaterial` の 5 段階から選ぶ。popover は `.regularMaterial` が標準
- `.overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15), lineWidth: 1))` で Ghost Border を足す

### 7.4 Color tokens の SwiftUI 実装

CaptionCraft は既存 `Color+Hex.swift` で `Color(hex: "#ADC6FF")` を呼べる。design token を SwiftUI Color に落とす:

```swift
extension Color {
    static let scSurface             = Color(hex: "#131313")
    static let scSurfaceContainerLow = Color(hex: "#1B1C1C")
    static let scSurfaceContainer    = Color(hex: "#1F2020")
    static let scSurfaceContainerHigh     = Color(hex: "#2A2A2A")
    static let scSurfaceContainerHighest  = Color(hex: "#353535")
    static let scPrimary             = Color(hex: "#ADC6FF")
    static let scPrimaryAccent       = Color(hex: "#007AFF")  // macOS accent blue
    static let scOnSurface           = Color(hex: "#E4E2E1")
    static let scOutlineVariant      = Color(hex: "#414755")
    // 半透明 overlays は .opacity() modifier で都度作る
}
```

配置: `CaptionCraft/Shared/DesignTokens.swift` を新設。

### 7.5 Light mode 対応 (Phase B で検討)

Stitch design_md は **dark mode only** (`colorMode: DARK`)。macOS の Light mode 切替時の挙動は Phase B で設計。現段階では CaptionCraft の Editor は dark 固定。

### 7.6 HUD Capsule との整合

既存 `HUDView.swift` は `Capsule().fill(.regularMaterial)` で実装されている (行 28 付近)。これは §4 の Glass surface 原則と既に整合している。新規の popover / sheet / sub-panel を作る時は同じパターンを踏襲:

```swift
SomeContent()
    .padding(16)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
        RoundedRectangle(cornerRadius: 12)
            .stroke(.white.opacity(0.15), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.4), radius: 20, y: 20)
```

---

## 8. 改訂履歴

- **2026-04-20** 初版。Stitch "Screen Source Selector Grid" プロジェクトの design_md を原典として、§7 に macOS/SwiftUI 補足を追加。採用案は `TASKS/FIX_04_SOURCE_SELECTOR_UX.md` で案 C (Compact List) と決定
