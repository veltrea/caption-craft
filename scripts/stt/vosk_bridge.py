#!/usr/bin/env python3
"""
Vosk ブリッジスクリプト — CaptionCraft SubprocessCaptionEngine 用。

Vosk (Kaldi ベース CTC) で音声を文字起こしし、
JSONL (1行1セグメント) で stdout に出力する。

使い方:
    python3 vosk_bridge.py --audio /path/to/audio.mp4 --language en

出力 (stdout, JSONL):
    {"text": "Hello world", "start_ms": 0, "end_ms": 3200, "confidence": 0.92}

依存:
    pip install vosk
    (setup_vosk.sh で venv ごとインストール可能)
"""

import argparse
import json
import sys
import os
import wave
import subprocess
import tempfile


VOSK_MODELS = {
    "en": "vosk-model-small-en-us-0.15",
    "ja": "vosk-model-small-ja-0.22",
    "zh": "vosk-model-small-cn-0.22",
    "fr": "vosk-model-small-fr-0.22",
    "de": "vosk-model-small-de-0.15",
    "es": "vosk-model-small-es-0.42",
    "ko": "vosk-model-small-ko-0.22",
}


def main():
    parser = argparse.ArgumentParser(description="Vosk STT bridge for CaptionCraft")
    parser.add_argument("--audio", required=True, help="音声/動画ファイルパス")
    parser.add_argument("--language", default="en", help="ISO 639-1 言語コード")
    parser.add_argument("--model-path", default=None, help="Vosk モデルディレクトリのパス")
    args = parser.parse_args()

    if not os.path.exists(args.audio):
        print(f"Error: ファイルが見つかりません: {args.audio}", file=sys.stderr)
        sys.exit(1)

    try:
        from vosk import Model, KaldiRecognizer, SetLogLevel
    except ImportError:
        print("Error: vosk がインストールされていません。scripts/stt/setup_vosk.sh を実行してください。", file=sys.stderr)
        sys.exit(1)

    SetLogLevel(-1)

    model_path = args.model_path
    if not model_path:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        models_dir = os.path.join(script_dir, "models")
        lang = args.language if args.language != "auto" else "en"
        model_name = VOSK_MODELS.get(lang, VOSK_MODELS["en"])
        model_path = os.path.join(models_dir, model_name)

    if not os.path.isdir(model_path):
        print(f"Error: モデルが見つかりません: {model_path}", file=sys.stderr)
        print("scripts/stt/setup_vosk.sh を実行してモデルをダウンロードしてください。", file=sys.stderr)
        sys.exit(1)

    print(f"Vosk モデルをロード中: {model_path}", file=sys.stderr)
    model = Model(model_path)

    wav_path = _convert_to_wav(args.audio)
    try:
        _transcribe(model, wav_path)
    finally:
        if wav_path != args.audio and os.path.exists(wav_path):
            os.unlink(wav_path)

    print("完了", file=sys.stderr)


def _convert_to_wav(audio_path: str) -> str:
    """ffmpeg で 16kHz mono WAV に変換する。"""
    if audio_path.lower().endswith(".wav"):
        try:
            wf = wave.open(audio_path, "rb")
            if wf.getnchannels() == 1 and wf.getframerate() == 16000:
                wf.close()
                return audio_path
            wf.close()
        except Exception:
            pass

    print("音声を WAV 16kHz mono に変換中…", file=sys.stderr)
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()

    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", audio_path,
             "-ar", "16000", "-ac", "1", "-f", "wav", tmp.name],
            capture_output=True, check=True,
        )
    except FileNotFoundError:
        print("Error: ffmpeg が見つかりません。brew install ffmpeg で導入してください。", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        print(f"Error: ffmpeg 変換失敗: {e.stderr.decode()[:200]}", file=sys.stderr)
        sys.exit(1)

    return tmp.name


def _transcribe(model, wav_path: str):
    """Vosk で文字起こしして JSONL 出力。"""
    wf = wave.open(wav_path, "rb")
    rec = KaldiRecognizer(model, wf.getframerate())
    rec.SetWords(True)

    results = []
    while True:
        data = wf.readframes(4000)
        if len(data) == 0:
            break
        if rec.AcceptWaveform(data):
            result = json.loads(rec.Result())
            if result.get("text"):
                results.append(result)

    final = json.loads(rec.FinalResult())
    if final.get("text"):
        results.append(final)

    wf.close()

    for r in results:
        text = r.get("text", "").strip()
        if not text:
            continue

        words = r.get("result", [])
        if words:
            start_ms = int(words[0]["start"] * 1000)
            end_ms = int(words[-1]["end"] * 1000)
            conf = sum(w.get("conf", 0.8) for w in words) / len(words)
        else:
            start_ms = 0
            end_ms = 0
            conf = 0.8

        line = json.dumps({
            "text": text,
            "start_ms": start_ms,
            "end_ms": end_ms,
            "confidence": round(conf, 3),
        }, ensure_ascii=False)
        print(line, flush=True)


if __name__ == "__main__":
    main()
