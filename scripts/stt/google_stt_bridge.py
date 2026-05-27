#!/usr/bin/env python3
"""
Google Cloud Speech-to-Text ブリッジスクリプト — CaptionCraft SubprocessCaptionEngine 用。

Google Cloud Speech-to-Text API で音声を文字起こしし、
JSONL (1行1セグメント) で stdout に出力する。

認証:
    環境変数 GOOGLE_APPLICATION_CREDENTIALS にサービスアカウント JSON のパスを設定する。
    または scripts/stt/google_credentials.json にファイルを配置する。

使い方:
    python3 google_stt_bridge.py --audio /path/to/audio.mp4 --language en-US

出力 (stdout, JSONL):
    {"text": "Hello world", "start_ms": 0, "end_ms": 3200, "confidence": 0.92}

依存:
    pip install google-cloud-speech pydub
    (setup_google_stt.sh で venv ごとインストール可能)
"""

import argparse
import json
import sys
import os
import subprocess
import tempfile
from typing import Optional


LANGUAGE_MAP = {
    "en": "en-US",
    "ja": "ja-JP",
    "zh": "zh-CN",
    "fr": "fr-FR",
    "de": "de-DE",
    "es": "es-ES",
    "ko": "ko-KR",
    "auto": "en-US",
}


def main():
    parser = argparse.ArgumentParser(description="Google Cloud STT bridge for CaptionCraft")
    parser.add_argument("--audio", required=True, help="音声/動画ファイルパス")
    parser.add_argument("--language", default="en", help="ISO 639-1 言語コード or 'auto'")
    parser.add_argument("--credentials", default=None, help="Google Cloud サービスアカウント JSON パス")
    args = parser.parse_args()

    if not os.path.exists(args.audio):
        print(f"Error: ファイルが見つかりません: {args.audio}", file=sys.stderr)
        sys.exit(1)

    _setup_credentials(args.credentials)

    try:
        from google.cloud import speech
    except ImportError:
        print("Error: google-cloud-speech がインストールされていません。scripts/stt/setup_google_stt.sh を実行してください。", file=sys.stderr)
        sys.exit(1)

    wav_path = _convert_to_wav(args.audio)

    try:
        _transcribe(speech, wav_path, args.language)
    finally:
        if wav_path != args.audio and os.path.exists(wav_path):
            os.unlink(wav_path)

    print("完了", file=sys.stderr)


def _setup_credentials(credentials_path: Optional[str]):
    """認証情報を設定する。"""
    if credentials_path and os.path.exists(credentials_path):
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = credentials_path
        return

    if os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
        return

    script_dir = os.path.dirname(os.path.abspath(__file__))
    local_creds = os.path.join(script_dir, "google_credentials.json")
    if os.path.exists(local_creds):
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = local_creds
        return

    print("Warning: Google Cloud 認証情報が設定されていません。", file=sys.stderr)
    print("GOOGLE_APPLICATION_CREDENTIALS 環境変数を設定するか、", file=sys.stderr)
    print("scripts/stt/google_credentials.json にファイルを配置してください。", file=sys.stderr)


def _convert_to_wav(audio_path: str) -> str:
    """ffmpeg で 16kHz mono WAV に変換する。"""
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


def _transcribe(speech, wav_path: str, language: str):
    """Google Cloud STT で文字起こしして JSONL 出力。"""
    client = speech.SpeechClient()

    with open(wav_path, "rb") as f:
        audio_content = f.read()

    audio = speech.RecognitionAudio(content=audio_content)

    lang_code = LANGUAGE_MAP.get(language, language)
    if "-" not in lang_code:
        lang_code = LANGUAGE_MAP.get(lang_code, f"{lang_code}-{lang_code.upper()}")

    config = speech.RecognitionConfig(
        encoding=speech.RecognitionConfig.AudioEncoding.LINEAR16,
        sample_rate_hertz=16000,
        language_code=lang_code,
        enable_word_time_offsets=True,
        enable_automatic_punctuation=True,
    )

    audio_size = len(audio_content)
    print(f"Google STT に送信中 ({audio_size / 1024 / 1024:.1f} MB, lang={lang_code})…", file=sys.stderr)

    if audio_size > 10 * 1024 * 1024:
        print("音声が長いため long_running_recognize を使用します…", file=sys.stderr)
        operation = client.long_running_recognize(config=config, audio=audio)
        response = operation.result(timeout=600)
    else:
        response = client.recognize(config=config, audio=audio)

    for result in response.results:
        alt = result.alternatives[0]
        text = alt.transcript.strip()
        if not text:
            continue

        confidence = alt.confidence if alt.confidence else 0.8

        words = alt.words
        if words:
            start_ms = int(words[0].start_time.total_seconds() * 1000)
            end_ms = int(words[-1].end_time.total_seconds() * 1000)
        else:
            start_ms = 0
            end_ms = 0

        line = json.dumps({
            "text": text,
            "start_ms": start_ms,
            "end_ms": end_ms,
            "confidence": round(confidence, 3),
        }, ensure_ascii=False)
        print(line, flush=True)


if __name__ == "__main__":
    main()
