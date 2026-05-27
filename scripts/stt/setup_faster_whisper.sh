#!/usr/bin/env bash
# faster-whisper STT エンジンのセットアップ。
#
# 使い方:
#   cd <project-root>
#   ./scripts/stt/setup_faster_whisper.sh
#
# 処理:
#   1. scripts/stt/venv/ に Python venv を作成 (既存なら再利用)
#   2. faster-whisper をインストール
#   3. 動作確認

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"
PYTHON="${VENV_DIR}/bin/python3"

echo "--- faster-whisper セットアップ ---"

# venv
if [ ! -d "$VENV_DIR" ]; then
    echo "venv を作成中…"
    python3 -m venv "$VENV_DIR"
else
    echo "既存の venv を再利用"
fi

# pip + faster-whisper
echo "faster-whisper をインストール中…"
"$PYTHON" -m pip install --upgrade pip --quiet
"$PYTHON" -m pip install --quiet faster-whisper

# 動作確認
echo "動作確認…"
"$PYTHON" "$SCRIPT_DIR/faster_whisper_bridge.py" --help > /dev/null 2>&1

echo ""
echo "セットアップ完了。"
echo "CaptionCraft のエンジン選択画面で faster-whisper を有効にしてください。"
echo ""
echo "初回実行時に Whisper モデル (small, ~460MB) が自動ダウンロードされます。"
echo ""
echo "手動テスト:"
echo "  $PYTHON $SCRIPT_DIR/faster_whisper_bridge.py --audio /path/to/audio.mp4 --language en"
