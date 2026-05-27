# アーキテクチャ

## レイヤー構成

```
┌──────────────────────────────────────────────────────────────┐
│                    Presentation Layer                         │
│  CaptionCraftApp     VideoEditorView     PreferencesView     │
│  EditorWindowController                                      │
│  PreviewAreaView  TimelineView  RightPanelView  ListenPanel  │
├──────────────────────────────────────────────────────────────┤
│                    Application Layer                          │
│  ProjectStore          PlaybackController                    │
│  CaptionTranscriber    CorrectionService                     │
│  TranslationService    RemoteControlServer (ACP)             │
├──────────────────────────────────────────────────────────────┤
│                      Domain Layer                            │
│  CaptionRegion    CaptionSettings    CorrectionRecord        │
│  CorrectionDictionary   EditorState   CaptionCraftProject    │
│  TimelineRegion (protocol)                                   │
├──────────────────────────────────────────────────────────────┤
│                      Engine Layer                            │
│  CaptionEngine (protocol)                                    │
│  ├── WhisperKitCaptionEngine   (WhisperKit)                  │
│  ├── ParakeetCaptionEngine     (SpeechSwift / Parakeet TDT)  │
│  ├── Qwen3CaptionEngine        (SpeechSwift / Qwen3)        │
│  └── FasterWhisperCaptionEngine (faster-whisper-server)      │
│  CaptionModelManager   VoiceActivityDetector                 │
│  CaptionSegmenter      AudioStretchRenderer (Signalsmith)    │
│  LLMClient             SRTCodec                              │
│  ListenEQProcessor     SliceDetector                         │
├──────────────────────────────────────────────────────────────┤
│                   Infrastructure Layer                        │
│  AVFoundation    WhisperKit     SpeechSwift (SPM)            │
│  Accelerate      Network (NWListener)                        │
│  Signalsmith Stretch (C++ vendor)                            │
│  AppKit          SwiftUI        WebKit (YouTube)             │
└──────────────────────────────────────────────────────────────┘
```

## ディレクトリ構造

```
CaptionCraft/
├── App/
│   ├── CaptionCraftApp.swift           @main, メニューバー定義
│   ├── AppDelegate.swift               ファイルオープン, YouTube URL, ウィンドウ管理
│   └── AboutView.swift                 About 画面
│
├── Models/
│   ├── Project.swift                   CaptionCraftProject (ルートモデル, Codable)
│   ├── ProjectStore.swift              プロジェクトの保存・読み込み・状態管理
│   ├── EditorState.swift               エディター状態 (アスペクト比, フレーム等)
│   ├── CaptionRegion.swift             字幕セグメント + VAD/STT 設定群
│   ├── Regions.swift                   TimelineRegion protocol
│   ├── CorrectionDictionary.swift      誤認識パターン辞書
│   └── CorrectionRecord.swift          校正履歴 1 件
│
├── Editor/
│   ├── VideoEditorView.swift           メイン画面 (プレビュー + タイムライン + 右パネル)
│   ├── EditorWindowController.swift    NSWindow ライフサイクル, SRT import/export
│   ├── EditorTheme.swift               UI テーマ定数
│   │
│   ├── Caption/                        ★ 字幕エンジン群
│   │   ├── CaptionEngine.swift         CaptionEngine protocol (STT の抽象化)
│   │   ├── WhisperKitCaptionEngine.swift
│   │   ├── ParakeetCaptionEngine.swift
│   │   ├── Qwen3CaptionEngine.swift
│   │   ├── FasterWhisperCaptionEngine.swift
│   │   ├── STTEngineType.swift         エンジン種別 enum
│   │   ├── CaptionModelManager.swift   Whisper モデルのダウンロード・管理
│   │   ├── CaptionTranscriber.swift    音声→字幕パイプライン全体 (1,699行, 最大級)
│   │   ├── CaptionSegmenter.swift      字幕セグメント分割
│   │   ├── VoiceActivityDetector.swift VAD (音声区間検出)
│   │   ├── CaptionOverlayView.swift    プレビュー上の字幕オーバーレイ
│   │   ├── SRTCodec.swift              SRT パース・シリアライズ
│   │   ├── CorrectionService.swift     LLM 校正オーケストレータ
│   │   ├── LLMClient.swift             OpenAI 互換 API クライアント
│   │   ├── DictionaryCorrector.swift   辞書ベース一括置換 (純粋関数)
│   │   ├── DictionaryStore.swift       辞書の JSON 永続化
│   │   ├── TranslationService.swift    LLM 翻訳
│   │   ├── EditDiffExtractor.swift     編集差分→辞書候補抽出 (純粋関数)
│   │   ├── EnsembleCheckSession.swift  複数エンジンのクロスチェック
│   │   ├── EnsembleCheckSheet.swift    クロスチェック UI
│   │   ├── PipelineHealthTracker.swift パイプライン健全性監視
│   │   └── PipelineDiagnostics.swift   診断情報
│   │
│   ├── Playback/
│   │   ├── PlaybackController.swift    AVPlayer 再生制御, ループ再生
│   │   ├── PlaybackControlsView.swift  再生コントロール UI
│   │   └── AudioStretchRenderer.swift  Signalsmith Stretch によるタイムストレッチ
│   │
│   ├── Timeline/
│   │   ├── TimelineView.swift          タイムライン UI (1,811行, 最大)
│   │   ├── TimelineViewModel.swift     タイムライン状態管理
│   │   ├── WaveformExtractor.swift     AVAsset → peak 配列 (逐次抽出)
│   │   ├── WaveformView.swift          波形 + 字幕リージョン描画
│   │   ├── TimelineResizeHandle.swift  リージョン境界ドラッグ
│   │   └── ScrollEventReceiver.swift   スクロールイベント処理
│   │
│   ├── PreviewArea/
│   │   ├── PreviewAreaView.swift       動画プレビュー領域
│   │   ├── VideoLayerView.swift        AVPlayerLayer ホスト
│   │   └── PreviewCanvasGeometry.swift プレビュー座標変換
│   │
│   ├── RightPanel/
│   │   ├── RightPanelView.swift        右パネル (タブ切替)
│   │   ├── CaptionPanel.swift          字幕設定・STT 操作
│   │   ├── CaptionListView.swift       字幕一覧
│   │   ├── TranslationPanel.swift      翻訳パネル
│   │   ├── CorrectionHistoryView.swift 校正履歴表示
│   │   ├── DictionaryManagerView.swift 辞書管理 UI
│   │   └── CollapsibleSection.swift    折りたたみセクション
│   │
│   ├── ListenPanel/                    聴き直しパネル
│   │   ├── ListenPanelView.swift       パネル全体
│   │   ├── ListenWaveformView.swift    ループ区間波形 + スライスジャンプ
│   │   ├── ListenEQProcessor.swift     MTAudioProcessingTap 2段階 EQ
│   │   ├── GraphicEQView.swift         10 バンドグライコ UI
│   │   └── SliceDetector.swift         無音区間/字幕境界でスライス検出
│   │
│   └── YouTube/
│       ├── YouTubeInputView.swift      URL 入力 UI
│       ├── YouTubeURLValidator.swift   URL バリデーション
│       ├── YouTubeWebView.swift        WKWebView (IFrame Player)
│       ├── YouTubePlayerController.swift JS ↔ Swift 双方向通信
│       ├── YouTubeAudioDownloader.swift yt-dlp 経由ダウンロード
│       └── YouTubeAudioCapture.swift   ScreenCaptureKit 音声キャプチャ
│
├── Localization/
│   ├── L10n.swift                      NSLocalizedString ラッパー
│   └── PromptManager.swift             AI プロンプトテンプレート管理
│
├── Preferences/
│   ├── PreferencesView.swift           設定ウィンドウ
│   ├── PreferencesStore.swift          UserDefaults ベースの設定永続化
│   └── EditingPreferencesPane.swift    編集設定ペイン
│
├── Shared/
│   ├── DesignTokens.swift              デザインシステム定数 (The Obsidian Lens)
│   ├── Color+Hex.swift                 色ユーティリティ
│   ├── AppLog.swift                    OSLog ラッパー
│   └── E2ETrackStub.swift              E2E テスト用スタブ
│
├── Support/
│   └── AINote.swift
│
├── Debug/
│   ├── RemoteControlServer.swift       HTTP サーバー本体 (NWListener, port 9876)
│   ├── RemoteControlServer+Pipeline.swift
│   ├── RemoteControlServer+Project.swift
│   ├── RemoteControlServer+Analysis.swift
│   ├── RemoteControlServer+Debug.swift
│   ├── RemoteControlServer+System.swift
│   ├── RemoteControlServer+YouTube.swift
│   └── ACPLogStore.swift               ACP ログ蓄積
│
├── Resources/
│   ├── Assets.xcassets/                アイコン等
│   ├── ja.lproj/                       日本語ローカライズ
│   └── en.lproj/                       英語ローカライズ
│
└── Vendor/
    └── Signalsmith/                    タイムストレッチ (C++, ヘッダオンリー)
```

## 外部依存

| ライブラリ | 導入方法 | 用途 |
|---|---|---|
| WhisperKit | SPM (0.9.0+) | Whisper モデルによる音声認識 |
| SpeechSwift / ParakeetASR | SPM (branch: main) | Parakeet TDT (NVIDIA FastConformer 系, 欧州25言語特化) |
| SpeechSwift / Qwen3ASR | SPM | Qwen3 音声認識 |
| SpeechSwift / AudioCommon | SPM | 音声ファイル読み込みユーティリティ |
| SpeechSwift / SpeechVAD | SPM | 音声区間検出 |
| Signalsmith Stretch | Vendor (C++ ヘッダ) | オフラインタイムストレッチ (速度変更) |
| Accelerate | System SDK | vDSP FFT, RMS 計算 |

## STT エンジンアーキテクチャ

`CaptionEngine` protocol により STT 実装を差し替え可能にしている。

```
CaptionEngine (protocol)
├── transcribe(url:language:...) async throws -> [TranscriptionSegment]
├── cancel()
└── isAvailable: Bool

実装:
├── WhisperKitCaptionEngine    CoreML + ANE, 多言語汎用
├── ParakeetCaptionEngine      CoreML + ANE, 欧州言語特化
├── Qwen3CaptionEngine         CoreML + ANE, Qwen3
└── FasterWhisperCaptionEngine 外部 faster-whisper-server 経由
```

`CaptionTranscriber` がパイプライン全体を統括する:

```
動画/音声 URL
  → 音声抽出 (AVAssetReader, PCM Float32 16kHz)
  → VAD (VoiceActivityDetector: 音声区間検出)
  → STT (CaptionEngine: 音声→テキスト)
  → セグメント分割 (CaptionSegmenter)
  → CaptionRegion 配列
```

## LLM 補正・翻訳パイプライン

ローカル LLM (LM Studio / Ollama) を OpenAI Chat Completions 互換 API で呼び出す。

```
CaptionRegion 配列
  → CorrectionService (文脈推定 → LLM 一括校正)
  → DictionaryCorrector (辞書ベース置換, 純粋関数)
  → TranslationService (LLM 翻訳)
  → 校正済み CaptionRegion 配列 + CorrectionRecord 履歴
```

`LLMClient` は localhost:1234 をデフォルトエンドポイントとする共用 HTTP クライアント。
`PromptManager` が Resources/Prompts/*.json からテンプレートを読み込む。

## ACP (Agent Control Protocol)

`RemoteControlServer` が port 9876 で HTTP サーバーを起動し、外部ツール (Claude 等) から CaptionCraft を操作可能にする。NWListener ベースの軽量実装。

主要エンドポイント:

| メソッド | パス | 用途 |
|---|---|---|
| GET | /status | アプリ状態 |
| GET | /project | プロジェクト情報 |
| GET | /regions | 字幕一覧 |
| GET | /engines | 利用可能な STT エンジン |
| GET | /health | パイプライン健全性 |
| GET | /statistics | 統計情報 |
| GET | /problems | 問題のある字幕 |
| GET | /diff | 校正差分 |
| POST | /transcribe | 字幕生成開始 |
| POST | /cancel | 字幕生成中止 |
| POST | /correct | LLM 校正実行 |
| POST | /translate | 翻訳実行 |
| POST | /ensemble | クロスチェック実行 |
| POST | /edit-region | 字幕編集 |
| POST | /export-srt | SRT エクスポート |
| POST | /save | プロジェクト保存 |
| POST | /open | ファイルを開く |
| POST | /settings | 設定変更 |

## 入力ソース

CaptionCraft は 3 種類の入力を受け付ける:

1. **ローカル動画ファイル** — NSOpenPanel で選択、AVPlayer で再生
2. **プロジェクトファイル** (.captioncraft / .screencraft / .openscreen 後方互換)
3. **YouTube URL** — WKWebView で再生 + yt-dlp でダウンロード or ScreenCaptureKit でキャプチャ

## SwiftUI と AppKit の使い分け

| 用途 | 採用技術 | 理由 |
|---|---|---|
| エディター本体 | SwiftUI | タイムライン・パネル等の宣言的 UI |
| ウィンドウ管理 | AppKit (NSWindow) | frame autosave, dirty 確認 |
| 動画プレビュー | AppKit (NSView) | AVPlayerLayer は CALayer ベース |
| ファイルダイアログ | AppKit | NSOpenPanel / NSSavePanel |
| YouTube 再生 | WebKit (WKWebView) | IFrame Player API |

## 状態管理

- **プロジェクト状態**: `ProjectStore` (@Observable) がプロジェクト全体を保持
- **再生状態**: `PlaybackController` (@Observable) が AVPlayer を管理
- **字幕生成状態**: `CaptionTranscriber` (@Observable) がパイプライン進捗を公開
- **設定**: `PreferencesStore` が UserDefaults を背景に @Published プロパティを公開
- **非同期処理**: Swift Concurrency (async/await) を全面採用

## プロジェクトファイル形式

拡張子 `.captioncraft` のディレクトリパッケージ。内部に `project.json` (CaptionCraftProject の Codable シリアライズ) とメディアファイルを格納。
