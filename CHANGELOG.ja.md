**他の言語で読む:** [English](CHANGELOG.md)

# 変更履歴

このファイルでは CaptionCraft の重要な変更点を記録します。フォーマットは [Keep a Changelog](https://keepachangelog.com/) に準拠し、バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従います。

---

## [v0.0.1] — 2026-05-27

最初の公開リリース。

### 機能

- **マルチエンジン STT**: WhisperKit (CoreML/ANE)、Parakeet TDT、Qwen3-ASR、faster-whisper
  - Whisper モデルは Tiny〜Large v3 Turbo まで 6 サイズから選択可能
- **VAD (音声区間検出)**: 無音区間の自動スキップ、VAD なしモードも選択可
- **アンサンブルクロスチェック**: 複数 STT エンジンの結果を突き合わせて精度検証
- **LLM 文脈補正**: ローカル LLM による字幕テキストの文脈修正
- **辞書ベース補正**: ユーザー定義の修正辞書 + 学習履歴による自動修正
- **翻訳**: ローカル LLM を使った字幕翻訳 (1 件ずつ + 前後文脈 + JSON Schema 強制)
- **YouTube モード**: YouTube URL から音声をキャプチャしてリアルタイム字幕生成
- **聴き直しパネル**: パラメトリック EQ (6 バンド) + グラフィック EQ (10 バンド)、スライスマーカー、速度変更再生
- **字幕フォーマット**: SRT 読み書き
- **タイムストレッチ**: Signalsmith Stretch によるピッチ維持の速度変更再生
- **ACP (Agent Control Protocol)**: localhost:9876 で外部ツールからアプリを操作可能
- **CJK 完全対応**: 日本語・中国語・韓国語の IME・言語コードに設計段階から対応

### 動作環境

- macOS 15.0 以降
- Apple Silicon (CoreML/Neural Engine 最適化)
- Xcode 16.4 / xcodegen (ビルド時)

[v0.0.1]: https://github.com/veltrea/caption-craft/releases/tag/v0.0.1
