#!/usr/bin/env bash
# Google Cloud Speech-to-Text STT エンジンのセットアップ。
#
# 使い方:
#   cd <project-root>
#   ./scripts/stt/setup_google_stt.sh
#
# 処理:
#   1. scripts/stt/venv/ に Python venv を作成 (既存なら再利用)
#   2. google-cloud-speech をインストール
#   3. 認証情報の確認
#
# 事前準備 (手動):
#   1. Google Cloud Console でプロジェクトを作成
#   2. Speech-to-Text API を有効化
#   3. サービスアカウントキー (JSON) をダウンロード
#   4. scripts/stt/google_credentials.json に配置
#      または GOOGLE_APPLICATION_CREDENTIALS 環境変数を設定

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"
PYTHON="${VENV_DIR}/bin/python3"

echo "--- Google Cloud Speech-to-Text セットアップ ---"

# venv
if [ ! -d "$VENV_DIR" ]; then
    echo "venv を作成中…"
    python3 -m venv "$VENV_DIR"
else
    echo "既存の venv を再利用"
fi

# pip + google-cloud-speech
echo "google-cloud-speech をインストール中…"
"$PYTHON" -m pip install --upgrade pip --quiet
"$PYTHON" -m pip install --quiet google-cloud-speech

# ffmpeg 確認
if ! command -v ffmpeg &> /dev/null; then
    echo "Warning: ffmpeg が見つかりません。brew install ffmpeg で導入してください。"
fi

# 認証情報確認
CREDS_PATH="$SCRIPT_DIR/google_credentials.json"
if [ -f "$CREDS_PATH" ]; then
    echo "認証情報ファイル検出: $CREDS_PATH"
elif [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
    echo "環境変数 GOOGLE_APPLICATION_CREDENTIALS が設定されています: $GOOGLE_APPLICATION_CREDENTIALS"
else
    echo ""
    echo "--- 認証情報が未設定です ---"
    echo "以下のいずれかを実施してください:"
    echo ""
    echo "  方法 1: ファイル配置"
    echo "    サービスアカウントキー (JSON) を以下にコピー:"
    echo "    $CREDS_PATH"
    echo ""
    echo "  方法 2: 環境変数"
    echo "    export GOOGLE_APPLICATION_CREDENTIALS=/path/to/credentials.json"
    echo ""
fi

# 動作確認
echo "動作確認…"
"$PYTHON" "$SCRIPT_DIR/google_stt_bridge.py" --help > /dev/null 2>&1

echo ""
echo "パッケージのセットアップ完了。"
echo "Google Cloud の認証情報を設定した後、CaptionCraft で Google STT を有効にしてください。"
echo ""
echo "手動テスト:"
echo "  $PYTHON $SCRIPT_DIR/google_stt_bridge.py --audio /path/to/audio.mp4 --language en"
