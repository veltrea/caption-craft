#!/usr/bin/env python3
"""
faster-whisper 多言語ブリッジスクリプト — CaptionCraft 用。

各言語を翻訳せず原語のまま書き起こす。言語学習者向け。

パイプライン:
    1. 音声を VAD で発話区間に分割
    2. 各区間の言語を自動検出
    3. 検出言語で書き起こし (翻訳しない)
    4. 確信度が低い区間は --default-lang で書き起こし

使い方:
    python3 faster_whisper_bridge.py --audio /path/to/video.mp4 --default-lang ja

出力 (stdout, JSONL):
    {"text": "こんにちは", "start_ms": 0, "end_ms": 2100, "lang": "ja", "confidence": 0.95}
    {"text": "Bonjour", "start_ms": 2500, "end_ms": 4800, "lang": "fr", "confidence": 0.92}

依存:
    pip install faster-whisper
"""

import argparse
import json
import math
import sys
import os


def main():
    parser = argparse.ArgumentParser(description="faster-whisper multilingual bridge for CaptionCraft")
    parser.add_argument("--audio", required=True, help="音声/動画ファイルパス")
    parser.add_argument("--language", default="auto",
                        help="ISO 639-1 言語コード or 'auto' (互換用。--default-lang と同義)")
    parser.add_argument("--default-lang", default=None,
                        help="言語検出が低確信度のときのフォールバック言語 (ISO 639-1)")
    parser.add_argument("--model-size", default="large-v3",
                        help="Whisper モデルサイズ (tiny/base/small/medium/large-v3)")
    parser.add_argument("--lang-threshold", type=float, default=0.6,
                        help="言語検出の確信度閾値。これ以下ならデフォルト言語を使う")
    parser.add_argument("--device", default="cpu", help="cpu or cuda")
    parser.add_argument("--compute-type", default="int8",
                        help="量子化タイプ (int8/float16/float32)")
    args = parser.parse_args()

    # --default-lang が未指定なら --language を使う (互換性)
    default_lang = args.default_lang or (args.language if args.language != "auto" else None)

    if not os.path.exists(args.audio):
        print(f"Error: ファイルが見つかりません: {args.audio}", file=sys.stderr)
        sys.exit(1)

    try:
        from faster_whisper import WhisperModel
    except ImportError:
        print("Error: faster-whisper がインストールされていません。", file=sys.stderr)
        print("  pip install faster-whisper", file=sys.stderr)
        sys.exit(1)

    print(f"faster-whisper モデルをロード中 ({args.model_size}, {args.device}, {args.compute_type})…",
          file=sys.stderr)
    model = WhisperModel(args.model_size, device=args.device, compute_type=args.compute_type)
    print("モデルロード完了", file=sys.stderr)

    print(f"書き起こし開始: {args.audio}", file=sys.stderr)
    print(f"  default_lang={default_lang or 'なし'}, threshold={args.lang_threshold}", file=sys.stderr)

    # ---- パス1: 言語自動検出で書き起こし ----
    try:
        segments, info = model.transcribe(
            args.audio,
            language=None,  # 自動検出
            beam_size=5,
            vad_filter=True,
            vad_parameters=dict(
                min_silence_duration_ms=500,
                speech_pad_ms=200,
            ),
        )
    except Exception as e:
        print(f"Error: 文字起こし失敗: {e}", file=sys.stderr)
        sys.exit(1)

    detected_lang = info.language
    detected_prob = info.language_probability
    print(f"  全体検出言語: {detected_lang} (prob={detected_prob:.3f})", file=sys.stderr)

    # 全体の言語検出が十分高確信度 → そのまま使う
    # 低確信度 かつ デフォルト言語指定あり → デフォルト言語で再書き起こし
    use_lang = detected_lang
    if detected_prob < args.lang_threshold and default_lang:
        print(f"  低確信度 → デフォルト言語 '{default_lang}' で再書き起こし", file=sys.stderr)
        use_lang = default_lang
        segments, info = model.transcribe(
            args.audio,
            language=default_lang,
            beam_size=5,
            vad_filter=True,
            vad_parameters=dict(
                min_silence_duration_ms=500,
                speech_pad_ms=200,
            ),
        )

    count = 0
    for segment in segments:
        text = segment.text.strip()
        if not text:
            continue

        confidence = _logprob_to_confidence(segment.avg_logprob)

        line = json.dumps({
            "text": text,
            "start_ms": int(segment.start * 1000),
            "end_ms": int(segment.end * 1000),
            "lang": use_lang,
            "confidence": round(confidence, 3),
        }, ensure_ascii=False)
        print(line, flush=True)
        count += 1

    print(f"完了: {count} segments", file=sys.stderr)


def _logprob_to_confidence(avg_logprob: float) -> float:
    """avg_logprob を 0-1 の confidence に変換する。"""
    if avg_logprob is None:
        return 0.8
    raw = math.exp(avg_logprob)
    return max(0.0, min(1.0, raw))


if __name__ == "__main__":
    main()
