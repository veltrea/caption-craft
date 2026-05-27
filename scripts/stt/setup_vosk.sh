#!/usr/bin/env bash
# Vosk STT エンジンのセットアップ。
#
# 使い方:
#   cd <project-root>
#   ./scripts/stt/setup_vosk.sh [--lang en|ja|zh|fr|de|es|ko]
#
# 処理:
#   1. scripts/stt/venv/ に Python venv を作成 (既存なら再利用)
#   2. vosk をインストール
#   3. 指定言語のモデルをダウンロード (デフォルト: en)
#   4. ffmpeg の存在確認

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"
PYTHON="${VENV_DIR}/bin/python3"
MODELS_DIR="$SCRIPT_DIR/models"

LANG="en"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lang) LANG="$2"; shift 2 ;;
        *) echo "Usage: $0 [--lang en|ja|zh|fr|de|es|ko]"; exit 1 ;;
    esac
done

echo "--- Vosk セットアップ ---"

# venv
if [ ! -d "$VENV_DIR" ]; then
    echo "venv を作成中…"
    python3 -m venv "$VENV_DIR"
else
    echo "既存の venv を再利用"
fi

# pip + vosk
echo "vosk をインストール中…"
"$PYTHON" -m pip install --upgrade pip --quiet
"$PYTHON" -m pip install --quiet vosk

# ffmpeg 確認
if ! command -v ffmpeg &> /dev/null; then
    echo "Warning: ffmpeg が見つかりません。brew install ffmpeg で導入してください。"
    echo "Vosk は音声を WAV 16kHz mono に変換する必要があります。"
fi

# モデルダウンロード
case "$LANG" in
    en) MODEL_URL="https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip" ;;
    ja) MODEL_URL="https://alphacephei.com/vosk/models/vosk-model-small-ja-0.22.zip" ;;
    zh) MODEL_URL="https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip" ;;
    fr) MODEL_URL="https://alphacephei.com/vosk/models/vosk-model-small-fr-0.22.zip" ;;
    de) MODEL_URL="https://alphacephei.com/vosk/models/vosk-model-small-de-0.15.zip" ;;
    es) MODEL_URL="https://alphacephei.com/vosk/models/vosk-model-small-es-0.42.zip" ;;
    ko) MODEL_URL="https://alphacephei.com/vosk/models/vosk-model-small-ko-0.22.zip" ;;
    *)
        echo "Error: 未対応の言語: $LANG"
        echo "対応言語: en, ja, zh, fr, de, es, ko"
        exit 1
        ;;
esac

MODEL_ZIP="$(basename "$MODEL_URL")"
MODEL_NAME="${MODEL_ZIP%.zip}"

mkdir -p "$MODELS_DIR"
if [ -d "$MODELS_DIR/$MODEL_NAME" ]; then
    echo "モデル $MODEL_NAME は既にダウンロード済み"
else
    echo "モデルをダウンロード中: $MODEL_NAME …"
    curl -L -o "$MODELS_DIR/$MODEL_ZIP" "$MODEL_URL"
    echo "展開中…"
    unzip -q "$MODELS_DIR/$MODEL_ZIP" -d "$MODELS_DIR"
    rm "$MODELS_DIR/$MODEL_ZIP"
    echo "モデルを配置: $MODELS_DIR/$MODEL_NAME"
fi

# 動作確認
echo "動作確認…"
"$PYTHON" "$SCRIPT_DIR/vosk_bridge.py" --help > /dev/null 2>&1

echo ""
echo "セットアップ完了 (言語: $LANG)。"
echo "CaptionCraft のエンジン選択画面で Vosk を有効にしてください。"
echo ""
echo "他の言語モデルを追加:"
echo "  $0 --lang ja    # 日本語"
echo "  $0 --lang fr    # フランス語"
echo ""
echo "手動テスト:"
echo "  $PYTHON $SCRIPT_DIR/vosk_bridge.py --audio /path/to/audio.mp4 --language $LANG"
