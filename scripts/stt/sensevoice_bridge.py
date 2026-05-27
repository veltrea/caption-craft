#!/usr/bin/env python3
"""
SenseVoice ブリッジスクリプト — CaptionCraft SubprocessCaptionEngine 用。

Alibaba FunASR の SenseVoice モデルで音声を文字起こしし、
JSONL (1行1セグメント) で stdout に出力する。

使い方:
    python3 sensevoice_bridge.py --audio /path/to/audio.mp4 --language en

出力 (stdout, JSONL):
    {"text": "Hello world", "start_ms": 0, "end_ms": 3200, "confidence": 0.92}
    {"text": "This is a test", "start_ms": 3500, "end_ms": 6100, "confidence": 0.88}

依存:
    pip install funasr torch torchaudio
    (setup.sh で venv ごとインストール可能)
"""

import argparse
import json
import sys
import os


def main():
    parser = argparse.ArgumentParser(description="SenseVoice STT bridge for CaptionCraft")
    parser.add_argument("--audio", required=True, help="音声/動画ファイルパス")
    parser.add_argument("--language", default="auto", help="ISO 639-1 言語コード or 'auto'")
    args = parser.parse_args()

    if not os.path.exists(args.audio):
        print(f"Error: ファイルが見つかりません: {args.audio}", file=sys.stderr)
        sys.exit(1)

    try:
        from funasr import AutoModel
    except ImportError:
        print("Error: funasr がインストールされていません。scripts/stt/setup.sh を実行してください。", file=sys.stderr)
        sys.exit(1)

    # SenseVoice モデルのロード
    # 初回はダウンロードが発生する (~500MB)
    print("SenseVoice モデルをロード中…", file=sys.stderr)
    model = AutoModel(
        model="iic/SenseVoiceSmall",
        trust_remote_code=True,
        device="cpu",  # macOS では CPU が安定。MPS 対応は将来検討。
    )

    # 言語マッピング (ISO 639-1 → SenseVoice の言語タグ)
    lang_map = {
        "auto": "auto",
        "zh": "zh",
        "en": "en",
        "ja": "ja",
        "ko": "ko",
        "fr": "fr",
        "de": "de",
        "es": "es",
    }
    sv_language = lang_map.get(args.language, "auto")

    print(f"文字起こし開始: {args.audio} (lang={sv_language})", file=sys.stderr)

    try:
        result = model.generate(
            input=args.audio,
            language=sv_language,
            use_itn=True,  # Inverse Text Normalization (数字→漢数字等)
            batch_size_s=60,
        )
    except Exception as e:
        print(f"Error: 文字起こし失敗: {e}", file=sys.stderr)
        sys.exit(1)

    if not result:
        print("Warning: 結果が空です", file=sys.stderr)
        sys.exit(0)

    # FunASR の結果をパースして JSONL 出力
    for item in result:
        if isinstance(item, dict):
            text = item.get("text", "")
            # SenseVoice はタイムスタンプを sentence レベルで返す
            # timestamp がない場合はファイル全体を 1 セグメントとして出力
            timestamps = item.get("timestamp", [])

            if timestamps:
                # タイムスタンプ付き: 各セグメントを出力
                sentences = item.get("sentence_info", [])
                if sentences:
                    for sent in sentences:
                        seg_text = sent.get("text", "")
                        start_ms = int(sent.get("start", 0))
                        end_ms = int(sent.get("end", 0))
                        confidence = float(sent.get("confidence", 0.8))
                        # SenseVoice の特殊タグを除去 (<|HAPPY|> 等)
                        seg_text = _strip_emotion_tags(seg_text)
                        if seg_text.strip():
                            line = json.dumps({
                                "text": seg_text.strip(),
                                "start_ms": start_ms,
                                "end_ms": end_ms,
                                "confidence": round(confidence, 3),
                            }, ensure_ascii=False)
                            print(line, flush=True)
                else:
                    # timestamp はあるが sentence_info がない場合
                    for ts_pair in timestamps:
                        if len(ts_pair) >= 2:
                            start_ms = int(ts_pair[0])
                            end_ms = int(ts_pair[1])
                            line = json.dumps({
                                "text": text.strip(),
                                "start_ms": start_ms,
                                "end_ms": end_ms,
                                "confidence": 0.8,
                            }, ensure_ascii=False)
                            print(line, flush=True)
            else:
                # タイムスタンプなし: 全体を 1 セグメント
                clean_text = _strip_emotion_tags(text)
                if clean_text.strip():
                    line = json.dumps({
                        "text": clean_text.strip(),
                        "start_ms": 0,
                        "end_ms": 0,
                        "confidence": 0.8,
                    }, ensure_ascii=False)
                    print(line, flush=True)

    print("完了", file=sys.stderr)


def _strip_emotion_tags(text: str) -> str:
    """SenseVoice の感情/イベントタグを除去する。
    例: <|HAPPY|>, <|BGM|>, <|Speech|>, <|NEUTRAL|> 等。
    """
    import re
    return re.sub(r"<\|[^|]+\|>", "", text)


if __name__ == "__main__":
    main()
