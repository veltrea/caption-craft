# ACP (Agent Control Protocol)

CaptionCraft は `CaptionCraft/Debug/RemoteControlServer.swift` + `RemoteControlServer+*.swift` で HTTP サーバー (port **9876**) を立てている。
これが **ACP (Agent Control Protocol)** で、Claude (および他のエージェント) は外部からアプリ機能を直接叩ける。

---

## 最初に叩くべきエンドポイント

`GET /` を叩くと **全エンドポイント仕様が JSON で返ってくる**。リクエスト引数の形式まで含まれる。

```bash
curl http://localhost:9876/
```

→ `{"endpoints": ["GET /status", "POST /open {youtube:URL} or {file:PATH}", ...]}`

**ソースコードを grep してプロトコルを推測する必要は一切ない。** 仕様確認は必ず `GET /` から。

---

## 主なエンドポイント (`GET /` で全部見えるので暗記不要)

| エンドポイント | 用途 |
|---|---|
| `GET /status` | 現在の状態 (リージョン数、翻訳状態、設定) |
| `POST /open {youtube:URL}` または `{file:PATH}` | 動画/ファイルを開く |
| `POST /transcribe` | 文字起こし |
| `POST /translate` | 翻訳 |
| `POST /correct {mode:"dictionary"\|"llm"}` | 補正 |
| `GET /regions` (フィルター: `?lang=fr`) | 字幕データ |
| `GET /problems?threshold=0.6` | 問題リージョン抽出 |
| `GET /diff?reference=youtube&lang=ja` | YouTube 自動字幕との差分 |
| `GET /logs?since=TIMESTAMP&category=transcribe&level=error` | ログ |
| `GET /screenshot` | スクリーンショット |
| `POST /export-srt {path,useTranslation?}` | SRT 書き出し |

---

## 当然のように使う

- **「翻訳バグ再現したい」** → `POST /translate` を叩いて `GET /regions` で結果確認、`GET /logs` で原因
- **「YouTube URL でテストしたい」** → `POST /open` に URL を投げる (yt-dlp 自動インストール)
- **「現状を確認したい」** → `GET /status` を最初に叩く

---

## 鉄則

CaptionCraft で **外部操作・自動テスト・状態確認・再現実験** のいずれかをやるなら、
**最初に `curl http://localhost:9876/status` を叩いて ACP が動いているか確認** する。
動いていれば yt-dlp や外部スクリプトを使う前に ACP で済まないか必ず先に検討する。

アプリ自体に Claude 操作用 HTTP API が組み込まれているのに、これを認識せずに `yt-dlp` を CLI から叩こうとしたり CLI 引数を考えたりするのは無駄手間。
