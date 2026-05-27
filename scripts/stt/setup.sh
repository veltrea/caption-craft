#!/usr/bin/env bash
# SenseVoice STT エンジンの Python 環境をセットアップする。
#
# 使い方:
#   cd <project-root>
#   ./scripts/stt/setup.sh
#
# 処理:
#   1. scripts/stt/venv/ に Python venv を作成 (既存なら再利用)
#   2. funasr, torch, torchaudio をインストール
#   3. sensevoice_bridge.py の動作確認 (--help のみ)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"
PYTHON="${VENV_DIR}/bin/python3"

echo "--- SenseVoice セットアップ ---"
echo "venv: $VENV_DIR"

# Step 1: venv 作成
if [ ! -d "$VENV_DIR" ]; then
    echo "venv を作成中…"
    python3 -m venv "$VENV_DIR"
else
    echo "既存の venv を再利用"
fi

# Step 2: pip upgrade + 依存インストール
echo "依存パッケージをインストール中…"
"$PYTHON" -m pip install --upgrade pip --quiet
"$PYTHON" -m pip install --quiet \
    funasr \
    torch \
    torchaudio \
    modelscope

# Step 3: 動作確認
echo "動作確認…"
"$PYTHON" "$SCRIPT_DIR/sensevoice_bridge.py" --help > /dev/null 2>&1

echo ""
echo "セットアップ完了。"
echo "CaptionCraft のエンジン選択画面で SenseVoice を有効にしてください。"
echo ""
echo "手動テスト:"
echo "  $PYTHON $SCRIPT_DIR/sensevoice_bridge.py --audio /path/to/audio.mp4 --language en"
