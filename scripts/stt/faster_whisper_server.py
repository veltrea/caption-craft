#!/usr/bin/env python3
"""
faster-whisper 常駐サーバー — CaptionCraft 多言語書き起こし用。

HTTP サーバーとして起動し、CaptionCraft (Swift) から POST リクエストで
音声チャンクを受け取り、言語検出 + 書き起こし結果を返す。

モデルは起動時に1回だけロードし、以降のリクエストは推論のみ。
これにより VAD パイプラインで大量のチャンクを高速に処理できる。

エンドポイント:
    POST /transcribe
        Body (JSON): {"audio_path": "/path/to/chunk.wav", "default_lang": "ja", "threshold": 0.6}
        Response: {"text": "...", "lang": "fr", "confidence": 0.92}

    POST /transcribe-file
        Body (JSON): {"audio_path": "/path/to/full.mp4", "default_lang": "ja"}
        Response: {"segments": [{"text":..., "start_ms":..., "end_ms":..., "lang":..., "confidence":...}, ...]}

    GET /health
        Response: {"status": "ready", "model": "large-v3"}

    POST /shutdown
        サーバーを終了する。

使い方:
    python3 faster_whisper_server.py --port 9877 --model large-v3
"""

import argparse
import json
import math
import sys
import os
import signal
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread

# グローバルモデル参照
_model = None
_model_size = None


class FasterWhisperHandler(BaseHTTPRequestHandler):
    """HTTP リクエストハンドラ。"""

    def log_message(self, format, *args):
        """stderr にログ出力。"""
        print(f"[server] {format % args}", file=sys.stderr)

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ready", "model": _model_size})
        else:
            self._respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/transcribe":
            self._handle_transcribe_chunk()
        elif self.path == "/transcribe-file":
            self._handle_transcribe_file()
        elif self.path == "/shutdown":
            self._respond(200, {"status": "shutting down"})
            # 別スレッドで停止 (レスポンス送信後)
            Thread(target=self.server.shutdown, daemon=True).start()
        else:
            self._respond(404, {"error": "not found"})

    def _handle_transcribe_chunk(self):
        """短いチャンク (WAV) を言語検出 + 書き起こし。"""
        body = self._read_body()
        if body is None:
            return

        audio_path = body.get("audio_path", "")
        default_lang = body.get("default_lang", None)
        threshold = body.get("threshold", 0.6)

        if not audio_path or not os.path.exists(audio_path):
            self._respond(400, {"error": f"audio_path not found: {audio_path}"})
            return

        try:
            # 言語自動検出で書き起こし
            segments, info = _model.transcribe(
                audio_path,
                language=None,
                beam_size=5,
                vad_filter=False,  # チャンクは既に VAD 済み
            )

            detected_lang = info.language
            detected_prob = info.language_probability

            # 低確信度 → デフォルト言語で再書き起こし
            if detected_prob < threshold and default_lang:
                segments, info = _model.transcribe(
                    audio_path,
                    language=default_lang,
                    beam_size=5,
                    vad_filter=False,
                )
                use_lang = default_lang
            else:
                use_lang = detected_lang

            texts = []
            total_logprob = 0.0
            seg_count = 0
            for seg in segments:
                t = seg.text.strip()
                if t:
                    texts.append(t)
                    if seg.avg_logprob is not None:
                        total_logprob += seg.avg_logprob
                        seg_count += 1

            text = " ".join(texts)
            avg_logprob = total_logprob / seg_count if seg_count > 0 else -0.5
            confidence = _logprob_to_confidence(avg_logprob)

            self._respond(200, {
                "text": text,
                "lang": use_lang,
                "confidence": round(confidence, 3),
                "lang_prob": round(detected_prob, 3),
            })

        except Exception as e:
            self._respond(500, {"error": str(e)})

    def _handle_transcribe_file(self):
        """ファイル全体を VAD + 書き起こし。"""
        body = self._read_body()
        if body is None:
            return

        audio_path = body.get("audio_path", "")
        default_lang = body.get("default_lang", None)
        threshold = body.get("threshold", 0.6)

        if not audio_path or not os.path.exists(audio_path):
            self._respond(400, {"error": f"audio_path not found: {audio_path}"})
            return

        try:
            segments, info = _model.transcribe(
                audio_path,
                language=None,
                beam_size=5,
                vad_filter=True,
                vad_parameters=dict(
                    min_silence_duration_ms=500,
                    speech_pad_ms=200,
                ),
            )

            detected_lang = info.language
            detected_prob = info.language_probability
            use_lang = detected_lang

            if detected_prob < threshold and default_lang:
                segments, info = _model.transcribe(
                    audio_path,
                    language=default_lang,
                    beam_size=5,
                    vad_filter=True,
                    vad_parameters=dict(
                        min_silence_duration_ms=500,
                        speech_pad_ms=200,
                    ),
                )
                use_lang = default_lang

            result_segments = []
            for seg in segments:
                text = seg.text.strip()
                if not text:
                    continue
                result_segments.append({
                    "text": text,
                    "start_ms": int(seg.start * 1000),
                    "end_ms": int(seg.end * 1000),
                    "lang": use_lang,
                    "confidence": round(_logprob_to_confidence(seg.avg_logprob), 3),
                })

            self._respond(200, {
                "segments": result_segments,
                "detected_lang": detected_lang,
                "detected_prob": round(detected_prob, 3),
            })

        except Exception as e:
            self._respond(500, {"error": str(e)})

    def _read_body(self):
        """リクエストボディを JSON としてパース。"""
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length)
            return json.loads(raw) if raw else {}
        except Exception as e:
            self._respond(400, {"error": f"invalid JSON: {e}"})
            return None

    def _respond(self, status, data):
        """JSON レスポンスを送信。"""
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def _logprob_to_confidence(avg_logprob: float) -> float:
    """avg_logprob を 0-1 の confidence に変換する。"""
    if avg_logprob is None:
        return 0.8
    raw = math.exp(avg_logprob)
    return max(0.0, min(1.0, raw))


def main():
    global _model, _model_size

    parser = argparse.ArgumentParser(description="faster-whisper HTTP server for CaptionCraft")
    parser.add_argument("--port", type=int, default=9877, help="ポート (default: 9877)")
    parser.add_argument("--model", default="large-v3", help="モデルサイズ")
    parser.add_argument("--device", default="cpu", help="cpu or cuda")
    parser.add_argument("--compute-type", default="int8", help="int8/float16/float32")
    args = parser.parse_args()

    _model_size = args.model

    print(f"Loading model: {args.model} ({args.device}, {args.compute_type})...", file=sys.stderr)
    from faster_whisper import WhisperModel
    _model = WhisperModel(args.model, device=args.device, compute_type=args.compute_type)
    print(f"Model loaded. Starting server on port {args.port}...", file=sys.stderr)

    server = HTTPServer(("127.0.0.1", args.port), FasterWhisperHandler)

    # SIGTERM でクリーンシャットダウン
    def _shutdown(sig, frame):
        print("\nShutting down...", file=sys.stderr)
        Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    print(f"Ready. http://127.0.0.1:{args.port}/health", file=sys.stderr)
    server.serve_forever()
    print("Server stopped.", file=sys.stderr)


if __name__ == "__main__":
    main()
