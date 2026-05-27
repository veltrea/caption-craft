**他の言語で読む:** [English](SPEC.md)

# CaptionCraft 機能仕様

CaptionCraft の機能スコープと振る舞いをまとめる。実装の詳細はリンク先のドキュメントを参照。

- アーキテクチャ: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- データモデル: [docs/DATA_MODELS.md](docs/DATA_MODELS.md)
- UI デザインシステム: [docs/DESIGN.md](docs/DESIGN.md)

---

## 1. プロダクトゴール

字幕の **生成・編集・保存** に特化した Mac ネイティブアプリ。聴覚障害者・字幕翻訳者・コンテンツクリエイターを主要ユーザーに想定。

### スコープ内
- 動画/音声からの字幕生成 (STT)
- 字幕テキストの校正・翻訳
- 字幕タイムラインの編集
- SRT 形式での読み書き
- 速度変更・EQ 付きの聴き直し再生

### スコープ外
- 動画録画
- 動画編集 (カット・トランジション・エフェクト)
- GIF / サムネイル生成
- クラウドへのアップロード

---

## 2. 対応環境

| 項目 | 要件 |
|---|---|
| OS | macOS 15.0+ |
| CPU | Apple Silicon (M1 以降) |
| メモリ | 16 GB 推奨 (8 GB でも動作するが大型 Whisper モデルでは厳しい) |
| ストレージ | アプリ本体 + 選択モデルにより 1〜10 GB |
| ネットワーク | 初回モデルダウンロード時のみ。以降は完全オフライン |

Intel Mac は非対応。CoreML / Neural Engine 前提の最適化を行っているため。

---

## 3. STT (音声→字幕生成)

### 3.1 利用可能なエンジン

| エンジン | 強み | バンドル方法 |
|---|---|---|
| WhisperKit | 多言語汎用 (99 言語)、CoreML + ANE | SPM |
| Parakeet TDT | 欧州 25 言語の精度、低レイテンシ | SPM (SpeechSwift) |
| Qwen3-ASR | Qwen3 ベース、多言語 | SPM (SpeechSwift) |
| faster-whisper | CPU/GPU、特殊用途・サーバー連携 | Python サブプロセス |

ユーザーは右パネルから用途に応じてエンジンを選択する。1 つに絞らずに複数提供する方針。

### 3.2 Whisper モデルサイズ

Tiny / Base / Small / Medium / Large v3 / Large v3 Turbo の 6 段階。CaptionModelManager がダウンロードと管理を行う。

### 3.3 VAD (音声区間検出)

- **既定**: SpeechVAD で無音をスキップし STT を呼び出す
- **VAD なしモード**: 連続音声として全体を STT に流す (短尺・密な音声向け)

### 3.4 アンサンブルクロスチェック

複数 STT エンジンで同一区間を処理し、差分を提示。`EnsembleCheckSession` が逐次オンデマンドで実行する (ANE/GPU 競合のため並列化はしない)。

---

## 4. LLM 文脈補正 / 翻訳

ローカル LLM (LM Studio / Ollama 等) を **OpenAI Chat Completions 互換 API** で呼び出す。クラウド API は呼ばない。

### 4.1 文脈補正

- **対象**: 字幕全体または選択範囲
- **手順**: `CorrectionService` が前後文脈を含めて LLM に校正依頼 → `CorrectionRecord` を履歴として保持
- **辞書補正**: `DictionaryCorrector` が純粋関数で一括置換 (LLM 呼び出し前後で利用可能)

### 4.2 翻訳

- **1 件ずつ + 前後文脈** を渡す方式
- **JSON Schema** で応答形式を強制
- バッチ翻訳・文脈なし翻訳は意図的に採用しない (精度劣化を避けるため)

### 4.3 LLM エンドポイント

既定で `http://localhost:1234`。設定画面から変更可能。

---

## 5. 字幕モデル

`CaptionRegion` が 1 セグメントを表す:

- 開始時刻 / 終了時刻 (秒)
- テキスト
- 信頼度 (STT 出力)
- 言語コード (BCP 47)
- 校正履歴へのリンク

詳細は [DATA_MODELS.md](docs/DATA_MODELS.md)。

---

## 6. ファイル入出力

### 6.1 入力

| 種別 | 形式 |
|---|---|
| ローカル動画 | AVFoundation が読める全形式 (mp4 / mov / mkv 等) |
| ローカル音声 | wav / mp3 / m4a / flac 等 |
| プロジェクトファイル | `.captioncraft` (新)、`.screencraft` / `.openscreen` (後方互換) |
| YouTube URL | WKWebView で再生 + yt-dlp ダウンロード or ScreenCaptureKit キャプチャ |

### 6.2 出力

| 種別 | 形式 |
|---|---|
| プロジェクト保存 | `.captioncraft` (ディレクトリパッケージ、内部 JSON) |
| 字幕エクスポート | SRT |
| 将来対応予定 | VTT / ASS |

---

## 7. 聴き直しパネル

字幕生成後の確認・修正を補助する音声プレビュー機能。

- **EQ**: パラメトリック EQ 6 バンド + グラフィック EQ 10 バンド (Biquad IIR)
- **スライス**: 字幕境界 / 無音検出で再生区間を区切ってジャンプ
- **速度変更**: Signalsmith Stretch でピッチ維持の 0.5x〜2.0x 再生
- **ループ再生**: 任意区間の繰り返し

---

## 8. ACP (Agent Control Protocol)

ローカル HTTP サーバー (`localhost:9876`、NWListener) を起動し、外部ツール (Claude Code 等) からアプリを操作可能にする。

主要エンドポイント:

| メソッド | パス | 用途 |
|---|---|---|
| GET | `/status` | アプリ状態取得 |
| POST | `/transcribe` | 字幕生成開始 |
| POST | `/correct` | LLM 校正実行 |
| POST | `/translate` | 翻訳実行 |
| POST | `/export-srt` | SRT エクスポート |
| POST | `/save` | プロジェクト保存 |

全エンドポイントは [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) を参照。

---

## 9. 多言語 / ローカライズ

- **UI 言語**: 日本語 / 英語 (Resources/ja.lproj, en.lproj)
- **CJK 一級市民**: 字幕言語コード・IME・縦書きに設計段階から対応
- **STT 対応言語**: 選択中のエンジンに依存 (Whisper は 99 言語、Parakeet は欧州 25 言語等)

---

## 10. 配布

- **ライセンス**: MIT
- **配布形式**: 自己署名 ad-hoc アプリ (将来的に Developer ID + 公証を検討)
- **公開リポ**: [github.com/veltrea/caption-craft](https://github.com/veltrea/caption-craft) (スナップショット)
- **内部開発履歴**: DEVLOG.md (非公開)
