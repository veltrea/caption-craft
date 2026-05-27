# データモデル設計

## プロジェクトファイル形式

拡張子 `.captioncraft`。実体はディレクトリパッケージ。

```
myproject.captioncraft/
├── project.json          ← 全編集状態 (Codable JSON)
├── media/
│   └── (動画/音声ファイル)
└── assets/
    └── (将来拡張用)
```

---

## ルートモデル

### CaptionCraftProject

ファイル: `Models/Project.swift`

```swift
struct CaptionCraftProject: Codable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var id: UUID
    var name: String = "Untitled"
    var createdAt: Date
    var modifiedAt: Date
    var media: MediaPaths
    var editor: EditorState
}
```

### MediaPaths

ファイル: `Models/Project.swift`

動画・音声ファイルへのパス情報。YouTube モードにも対応。

```swift
struct MediaPaths: Codable {
    var screenVideoPath: String       // 動画ファイルパス
    var createdAt: Date
    var durationMs: Int               // 動画長 (ms)
    var youtubeURL: String?           // YouTube モード時の URL
    var capturedAudioPath: String?    // ScreenCaptureKit で取得した音声
    var captureOffsetMs: Int = 0      // YouTube 再生オフセット

    var isYouTubeMode: Bool { youtubeURL != nil }  // computed
}
```

---

## エディタ状態

### EditorState

ファイル: `Models/EditorState.swift`

```swift
struct EditorState: Codable {
    var aspectRatio: AspectRatio = .widescreen
    var captionRegions: [CaptionRegion] = []
    var captionSettings: CaptionSettings = .default
}
```

### AspectRatio

ファイル: `Models/EditorState.swift`

```swift
enum AspectRatio: String, Codable, CaseIterable {
    case widescreen    = "16:9"
    case portrait      = "9:16"
    case standard      = "4:3"
    case portraitStd   = "3:4"
    case square        = "1:1"
    case ultraWide     = "21:9"
    case ultraPortrait = "9:21"
    case custom
}
```

### NormalizedRect / NormalizedPoint

ファイル: `Models/EditorState.swift`

```swift
struct NormalizedRect: Codable, Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
}

struct NormalizedPoint: Codable, Equatable {
    var cx: Double; var cy: Double
}
```

---

## 字幕モデル

### CaptionRegion

ファイル: `Models/CaptionRegion.swift`

字幕の 1 セグメント。タイムライン上の区間 + テキスト + メタデータ。

```swift
struct CaptionRegion: Codable, Identifiable, Equatable, TimelineRegion {
    var id: UUID
    var startMs: Int                        // 開始時刻 (ms)
    var endMs: Int                          // 終了時刻 (ms)
    var text: String                        // 字幕テキスト
    var translatedText: String?             // 翻訳テキスト
    var translatedLanguage: String?         // 翻訳先言語 (ISO 639-1)
    var isManuallyEdited: Bool = false      // 手動編集済み → 再合成から保護
    var sourceLanguage: String = "ja"       // 認識言語 (ISO 639-1)
    var confidence: Double = 1.0            // Whisper avg_logprob 由来 (0-1)
    var corrections: [CorrectionRecord]     // 修正履歴
    var originalRawText: String?            // 補正前の Whisper 生出力
    var engineResults: [String: String]     // アンサンブルチェック結果 (エンジン名: テキスト)
}
```

### TimelineRegion (Protocol)

ファイル: `Models/Regions.swift`

```swift
protocol TimelineRegion: Identifiable where ID == UUID {
    var id: UUID { get }
    var startMs: Int { get set }
    var endMs: Int { get set }
}
```

### CaptionSettings

ファイル: `Models/CaptionRegion.swift`

字幕生成のパラメータ。プロジェクト単位で保持。

```swift
struct CaptionSettings: Codable, Equatable {
    var language: String = "ja"                    // 主言語 (ISO 639-1 / "auto")
    var additionalLanguages: [String] = []         // 多言語マルチパス用
    var silenceSplitMs: Int = 350                  // 無音分割閾値 (ms)
    var minSegmentMs: Int = 500                    // 最短セグメント長 (ms)
    var maxWordsPerSegment: Int = 10               // スペース区切り言語の上限
    var domainHints: [String] = []                 // 文脈推定ヒント
    var autoCorrectWithDictionary: Bool = true     // 辞書自動補正
    var autoCorrectWithLLM: Bool = false           // LLM 自動補正
    var splitLongRegions: Bool = true              // 長いリージョンの後分割
    var vadMethod: VADMethod = .energy             // VAD 方式
    var vadSensitivity: VADSensitivity = .normal   // VAD 感度
    var vadCalibration: VADCalibration?             // VAD キャリブレーション結果

    var isMultilingual: Bool  // computed: !additionalLanguages.isEmpty
    var allLanguages: [String]  // computed: [language] + additionalLanguages
}
```

### VADMethod / VADSensitivity / VADCalibration

ファイル: `Models/CaptionRegion.swift`

```swift
enum VADMethod: String, Codable, CaseIterable {
    case energy   // RMS ベース、CPU のみ、高速、クリーン音声向き
    case silero   // Silero VAD v5、MLX/Metal GPU、BGM/ノイズ環境向き
    case none     // VAD なし、30 秒チャンクを直接 Whisper に渡す
}

enum VADSensitivity: String, Codable, CaseIterable, Identifiable {
    case low      // 誤検出を抑える
    case normal   // 標準
    case high     // 取りこぼしを減らす
    // 各ケースに sileroOnset/Offset, energyWindow 等のパラメータが紐づく
}

struct VADCalibration: Codable, Equatable {
    var quietRMS: Float                  // 静音時 RMS
    var loudRMS: Float                   // 大声時 RMS
    var deactivationThreshold: Float     // computed
    var activationThreshold: Float       // computed
}
```

### CaptionRenderStatus

ファイル: `Models/CaptionRegion.swift`

UI 専用。Codable ではない。

```swift
enum CaptionRenderStatus: Equatable {
    case idle
    case loadingModel(progress: Double, message: String)
    case transcribing(progress: Double)    // 0.0-1.0
    case correcting(phase: CorrectionPhase, progress: String)
    case failed(String)
}

enum CorrectionPhase: String, Equatable {
    case dictionary   // 辞書適用中
    case analyzing    // 文脈推定中
    case correcting   // LLM 校正中
}
```

---

## 補正モデル

### CorrectionRecord

ファイル: `Models/CorrectionRecord.swift`

1 回の修正操作の記録。CaptionRegion.corrections に蓄積される。

```swift
struct CorrectionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let regionID: UUID           // 対象 CaptionRegion
    let originalText: String     // 修正前テキスト
    let correctedText: String    // 修正後テキスト
    let source: CorrectionSource
    let timestamp: Date
}

enum CorrectionSource: String, Codable {
    case dictionary   // 辞書による自動補正
    case llm          // LLM による校正
    case userEdit     // ユーザー手動編集
}
```

### CorrectionDictionary

ファイル: `Models/CorrectionDictionary.swift`

誤認識パターンの辞書。プロジェクト横断で再利用。

```swift
struct CorrectionDictionary: Codable {
    var entries: [DictionaryEntry] = []
    func findEntries(matching text: String) -> [DictionaryEntry]
}

struct DictionaryEntry: Codable, Identifiable {
    let id: UUID
    var wrong: String             // 誤認識パターン
    var correct: String           // 正しいテキスト
    var caseSensitive: Bool
    var source: DictionaryEntrySource
    var useCount: Int
    var createdAt: Date
}

enum DictionaryEntrySource: String, Codable {
    case autoLearned     // ユーザー編集から自動学習
    case manual          // ユーザーが辞書に直接登録
    case llmSuggested    // LLM が提案
}
```

### CorrectionContext / SuggestedCorrection

ファイル: `Models/CorrectionDictionary.swift`

LLM 校正パイプラインで使用する文脈情報。

```swift
struct CorrectionContext: Codable {
    let domain: String                                // 推定ドメイン
    let keyTerms: [String]                            // 専門用語リスト
    let suggestedCorrections: [SuggestedCorrection]
}

struct SuggestedCorrection: Codable {
    let wrong: String
    let correct: String
    let confidence: Double    // 0-1
    let reasoning: String     // 修正理由
}
```

---

## STT エンジンモデル

### STTEngineType

ファイル: `Editor/Caption/STTEngineType.swift`

```swift
enum STTEngineType: String, CaseIterable, Codable, Identifiable {
    case whisper         // OpenAI Whisper Large v3 (WhisperKit)、99 言語
    case parakeet        // NVIDIA Parakeet TDT v3 (SpeechSwift)、欧州 25 言語
    case qwen3           // Alibaba Qwen3-ASR (SpeechSwift)、52 言語、コードスイッチ対応
    case fasterWhisper   // CTranslate2 int8、多言語、翻訳なし

    var displayName: String
    var summary: String
    var supportedLanguageCodes: Set<String>
    var supportsNoVAD: Bool
    func supports(language: String) -> Bool
}
```

### WhisperModelVariant

ファイル: `Editor/Caption/STTEngineType.swift`

```swift
enum WhisperModelVariant: String, CaseIterable, Codable, Identifiable {
    case tiny       = "openai_whisper-tiny"           // 39M
    case base       = "openai_whisper-base"           // 74M
    case small      = "openai_whisper-small"          // 244M
    case medium     = "openai_whisper-medium"         // 769M
    case largev3    = "openai_whisper-large-v3"       // 1.5B
    case turbo      = "openai_whisper-large-v3-turbo" // 809M (蒸留版)
}
```

---

## プリファレンス

### PreferencesStore

ファイル: `Preferences/PreferencesStore.swift`

アプリ全体の設定。UserDefaults に永続化。新規プロジェクト作成時の初期値になる。

```swift
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    @Published var whisperLanguage: String          // ISO 639-1
    @Published var silenceSplitMs: Int
    @Published var maxWordsPerSegment: Int
    @Published var sttEngine: STTEngineType
    @Published var whisperModelVariant: WhisperModelVariant

    func saveWhisperSettings(_ s: CaptionSettings)
    func loadWhisperSettings() -> CaptionSettings
    func resetAll()
}
```

---

## ProjectStore

ファイル: `Models/ProjectStore.swift`

プロジェクトの読み書き + Undo/Redo を管理するシングルトン。

```swift
final class ProjectStore: ObservableObject {
    @Published private(set) var project: CaptionCraftProject?
    @Published private(set) var isDirty: Bool = false
    @Published var scrollToRegionID: UUID?

    var savedURL: URL?
    private var past: [EditorState] = []      // Undo 履歴 (最大 80)
    private var future: [EditorState] = []    // Redo 履歴

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    func load(from url: URL) throws
    func save(to url: URL) throws
    func saveAs() throws -> URL
}

enum FileError: LocalizedError {
    case noProjectLoaded
    case pathTraversalDetected
    case packageCorrupted(reason: String)
    case mediaFileMissing(path: String)
}
```

---

## モデル関連図

```
CaptionCraftProject
├── MediaPaths              ... 動画/音声パス + YouTube 情報
└── EditorState
    ├── AspectRatio          ... プレビュー比率
    ├── [CaptionRegion]      ... 字幕セグメント群
    │   ├── [CorrectionRecord]  ... 修正履歴
    │   └── engineResults       ... アンサンブル結果
    └── CaptionSettings      ... 生成パラメータ
        ├── VADMethod
        ├── VADSensitivity
        └── VADCalibration?

CorrectionDictionary        ... プロジェクト横断辞書 (別ファイル)
├── [DictionaryEntry]
└── CorrectionContext       ... LLM 用文脈

PreferencesStore            ... アプリ設定 (UserDefaults)
├── STTEngineType
└── WhisperModelVariant
```
