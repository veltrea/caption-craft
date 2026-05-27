**他の言語で読む:** [English](README.md)

# CaptionCraft

**Mac ネイティブの AI 字幕エディタ**。聴覚障害者・字幕翻訳者・コンテンツクリエイターのための字幕特化ツール。

ローカル AI による音声認識・文脈補正・翻訳をすべてオフラインで完結。クラウドに音声を送信しない設計。

---

## 主な機能

- **マルチエンジン STT**: WhisperKit (CoreML/ANE)、Parakeet TDT、Qwen3-ASR、faster-whisper から用途に応じて選択
- **VAD (音声区間検出)**: SpeechVAD による無音区間の自動スキップ、VAD なしモードも選択可
- **アンサンブルクロスチェック**: 複数 STT エンジンの結果を突き合わせて認識精度を検証
- **LLM 文脈補正**: ローカル LLM による字幕テキストの文脈修正
- **辞書ベース補正**: ユーザー定義の修正辞書 + 学習履歴による自動修正
- **翻訳**: ローカル LLM を使った字幕翻訳
- **YouTube モード**: YouTube URL から音声をキャプチャしてリアルタイム字幕生成
- **聴き直しパネル**: パラメトリック EQ (6 バンド) + グラフィック EQ (10 バンド)、スライスマーカー、速度変更再生
- **字幕フォーマット**: SRT 読み書き (VTT/ASS は将来対応予定)
- **CJK 一級市民**: 設計段階から正しい言語コード・IME 完全対応

## 技術スタック

| 用途 | フレームワーク |
|---|---|
| STT (Whisper) | [WhisperKit](https://github.com/argmaxinc/WhisperKit) — CoreML + Neural Engine |
| STT (Parakeet/Qwen3) | [SpeechSwift](https://github.com/soniqo/speech-swift) — CoreML ネイティブ |
| STT (faster-whisper) | Python サブプロセス (CPU/GPU、多言語特化) |
| VAD | SpeechVAD (SpeechSwift 内蔵) |
| 音声タイムストレッチ | [Signalsmith Stretch](https://signalsmith-audio.co.uk/code/stretch/) (C++、Vendor 同梱) |
| オーディオ EQ | Biquad IIR フィルタ (MTAudioProcessingTap) |
| 字幕レンダリング | SwiftUI / AppKit |
| 動画再生 | AVFoundation (AVPlayer) |
| LLM 補正・翻訳 | ローカル LLM クライアント (LLMClient) |
| データ | Swift Codable / JSON |

## ビルド

```bash
# 初回のみ: 自己署名 cert を作成
scripts/setup_dev_cert.sh

# ビルド + 起動
scripts/run.sh

# 再起動 / 停止 / 状態確認
scripts/run.sh restart
scripts/run.sh stop
scripts/run.sh status
```

要件: macOS 15.0+ / Xcode 16.4 / [xcodegen](https://github.com/yonaskolb/XcodeGen) / Apple Silicon

## ソース構成

```
CaptionCraft/
├── App/                  # アプリ起動・AppDelegate
├── Editor/
│   ├── Caption/          # STT エンジン群・VAD・LLM 補正・辞書・アンサンブル
│   ├── ListenPanel/      # 聴き直しパネル (EQ・波形・スライス)
│   ├── Playback/         # 再生制御・タイムストレッチ
│   ├── PreviewArea/      # 動画プレビュー + 字幕オーバーレイ
│   ├── RightPanel/       # 字幕リスト・補正履歴・翻訳パネル
│   ├── Timeline/         # タイムライン・波形表示
│   └── YouTube/          # YouTube モード (音声キャプチャ・WebView)
├── Localization/         # L10n・プロンプト管理
├── Models/               # CaptionRegion・Project・ProjectStore
├── Preferences/          # 設定画面
├── Shared/               # DesignTokens・AppLog・ユーティリティ
├── Vendor/Signalsmith/   # タイムストレッチ C++ ライブラリ
└── Debug/                # RemoteControlServer (E2E/デバッグ用)
scripts/
├── run.sh                # ビルド + 起動ワンショット
├── setup_dev_cert.sh     # 自己署名証明書の作成
├── build.sh              # xcodebuild ラッパー
└── stt/                  # Python STT ブリッジ・セットアップ
docs/                     # 設計ドキュメント群
```

## ドキュメント

| ファイル | 内容 |
|---|---|
| [SPEC.ja.md](SPEC.ja.md) | 機能仕様 |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | 全体アーキテクチャ |
| [DESIGN.md](docs/DESIGN.md) | UI デザインシステム ("The Obsidian Lens") |
| [DATA_MODELS.md](docs/DATA_MODELS.md) | データモデル設計 |
| [CHANGELOG.ja.md](CHANGELOG.ja.md) | 変更履歴 |
| [THIRD_PARTY_LICENSES.md](docs/THIRD_PARTY_LICENSES.md) | サードパーティライセンス |

## 設計方針

- **Mac 専用 / ネイティブ品質**: クロスプラットフォーム化はしない
- **オフライン完結**: ローカル STT + ローカル LLM、クラウド送信なし
- **CJK 一級市民**: 設計段階から正しい言語コード・IME 完全対応
- **アクセシビリティ重視**: 聴覚障害者向け機能を後付けではなく最初から設計
- **マルチエンジン**: STT エンジンを1つに絞らず、用途・言語に応じて複数提供

## ライセンス

[MIT](LICENSE)
