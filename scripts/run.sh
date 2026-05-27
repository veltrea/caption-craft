#!/usr/bin/env bash
# CaptionCraft を E2E モードでビルド+起動するヘルパー。
#
# 使い方:
#   ./scripts/run.sh                起動 (ビルド込み。既に起動中ならエラー)
#   ./scripts/run.sh restart        停止 → ビルド → 起動
#   ./scripts/run.sh stop           既存プロセスを停止
#   ./scripts/run.sh status         稼働状況を表示
#   ./scripts/run.sh install        DerivedData から ~/Applications へコピー+再署名のみ
#                                   (ビルド済み前提。CI やデバッグ用途)
#
# オプション (start / restart のみ):
#   --clean       DerivedData を削除してからビルド (フルクリーンビルド)
#   --no-build    ビルドをスキップ (DerivedData の既存成果物を使う)
#                 ソース未変更時の高速再起動に限定して使うこと
#
# 挙動:
#   1. 既存プロセス停止 (restart のみ)
#   2. [--clean] DerivedData/CaptionCraft-* を削除
#   3. xcodegen generate で pbxproj を再生成
#   4. xcodebuild build (clean build if --clean)
#   5. ~/Applications/CaptionCraft.app に同期コピー
#      (DerivedData 配下の .app は System Settings の Privacy pane が
#       アイコン解決を拒否するため、~/Applications 側で運用する)
#   6. AppIcon.icns を完全版 (/tmp/FullAppIcon.icns) で差し替え (存在時のみ)
#   7. 内側 dylib → 外側 bundle の順で再署名
#   8. LaunchServices に強制再登録
#   9. ~/Applications 側を open -n で起動
#
# 環境変数で上書き可能:
#   CAPTIONCRAFT_E2E_PORT   E2E サーバーのポート (既定: 9876)
#   CAPTIONCRAFT_AGENT_MODE "debug" | "off" など (既定: debug)
#   CAPTIONCRAFT_LOG        ログ出力先 (既定: /tmp/cc.log)
#   CAPTIONCRAFT_CERT       署名に使う cert 名 (既定: "CaptionCraft Local Dev")
#
# 前提:
#   - scripts/setup_dev_cert.sh を 1 回実行して自己署名 cert を作成済み
#   - AppIcon.icns の完全版を生成したい場合は別途 /tmp/FullAppIcon.icns を用意

set -eu

PORT="${CAPTIONCRAFT_E2E_PORT:-9876}"
MODE="${CAPTIONCRAFT_AGENT_MODE:-debug}"
LOG="${CAPTIONCRAFT_LOG:-/tmp/cc.log}"
CERT="${CAPTIONCRAFT_CERT:-CaptionCraft Local Dev}"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/CaptionCraft.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister
BUILD_LOG="/tmp/cc-build.log"

# プロジェクトルート (scripts/ の親) に移動
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# サブコマンド + フラグ分解
SUBCMD="start"
DO_CLEAN=0
DO_BUILD=1
OPEN_FILE=""

if [ "$#" -gt 0 ]; then
  case "$1" in
    start|stop|restart|status|install) SUBCMD="$1"; shift ;;
  esac
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --clean)    DO_CLEAN=1 ;;
    --no-build) DO_BUILD=0 ;;
    --open)
      shift
      OPEN_FILE="$1"
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
  shift
done

find_derived_app() {
  local app
  app=$(ls -td ~/Library/Developer/Xcode/DerivedData/CaptionCraft-*/Build/Products/Debug/CaptionCraft.app 2>/dev/null | head -1 || true)
  if [ -z "${app:-}" ]; then
    echo "CaptionCraft.app (Debug) が DerivedData に見つかりません。先にビルドしてください。" >&2
    return 1
  fi
  printf '%s\n' "$app"
}

current_pid() {
  pgrep -f "CaptionCraft.app/Contents/MacOS/CaptionCraft" | head -1 || true
}

stop_existing() {
  local pid
  pid=$(current_pid)
  if [ -z "$pid" ]; then
    echo "起動中の CaptionCraft はありません"
    return 0
  fi
  echo "既存プロセス PID $pid を停止中..."
  # AppleScript の quit で正常終了させる (未保存確認ダイアログを抑制して即終了)。
  # kill だと SIGTERM で強制終了され、applicationShouldTerminate が呼ばれない。
  osascript -e 'tell application "CaptionCraft" to quit saving no' 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "停止完了"
      return 0
    fi
    sleep 1
  done
  echo "応答なし --- SIGKILL"
  kill -9 "$pid" 2>/dev/null || true
}

build_project() {
  # DerivedData クリーン (フルクリーン時のみ)
  if [ "$DO_CLEAN" -eq 1 ]; then
    echo "--- DerivedData クリーン (CaptionCraft-*)"
    find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name 'CaptionCraft-*' -exec rm -rf {} + 2>/dev/null || true
  fi

  # pbxproj 再生成 (新規 Swift ファイル追加対応)
  echo "--- xcodegen generate"
  xcodegen generate

  # xcodebuild
  local action="build"
  [ "$DO_CLEAN" -eq 1 ] && action="clean build"
  echo "--- xcodebuild $action (Debug)"

  set +e
  # WhisperKit の SPM 依存 (swift-crypto 等) が要求する署名 (team 必須) と
  # 本体の Local Dev cert を両立させるため、プロジェクトデフォルトは ad-hoc (`-`) に
  # 落として SPM deps を通す。本体 CaptionCraft.app は install ステップで
  # codesign --force で Local Dev cert に貼り直される (本 script の後半参照)。
  # Local Dev cert が必要な理由: ad-hoc だと CDHash が毎ビルド変わり TCC
  # (画面収録/マイク) の許可が毎回リセットされる (CLAUDE.md §5.3)。
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild \
      -project CaptionCraft.xcodeproj \
      -scheme CaptionCraft \
      -configuration Debug \
      -destination 'platform=macOS' \
      CODE_SIGN_IDENTITY=- \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGNING_REQUIRED=YES \
      CODE_SIGNING_ALLOWED=YES \
      $action \
      > "$BUILD_LOG" 2>&1
  local build_exit=$?
  set -e

  if [ "$build_exit" -ne 0 ]; then
    echo "--- ビルド失敗 (exit $build_exit)"
    echo "--- エラー行抽出:"
    grep -E "(error:|BUILD FAILED)" "$BUILD_LOG" | head -50
    echo "--- 詳細ログ: $BUILD_LOG"
    exit "$build_exit"
  fi

  echo "--- ビルド成功 ($(grep -cE 'warning:' "$BUILD_LOG" || echo 0) warnings)"
}

install_to_applications() {
  local src
  src=$(find_derived_app) || return 1
  echo "--- DerivedData: $src"
  echo "--- ~/Applications にコピー"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALLED_APP"
  cp -R "$src" "$INSTALLED_APP"

  if [ -f /tmp/FullAppIcon.icns ]; then
    echo "--- AppIcon.icns を完全版で差し替え"
    cp -f /tmp/FullAppIcon.icns "$INSTALLED_APP/Contents/Resources/AppIcon.icns"
  fi

  echo "--- 再署名 (cert: $CERT)"
  local dylib
  for dylib in "$INSTALLED_APP/Contents/MacOS"/*.dylib; do
    [ -f "$dylib" ] && codesign --force --sign "$CERT" "$dylib" 2>&1 | tail -1
  done
  codesign --force --sign "$CERT" "$INSTALLED_APP" 2>&1 | tail -1

  echo "--- LaunchServices 再登録"
  "$LSREG" -f "$INSTALLED_APP"

  local dd_app
  for dd_app in ~/Library/Developer/Xcode/DerivedData/CaptionCraft-*/Build/Products/*/CaptionCraft.app; do
    [ -e "$dd_app" ] && "$LSREG" -u "$dd_app" >/dev/null 2>&1 || true
  done

  echo "--- インストール完了: $INSTALLED_APP"
}

start() {
  local pid
  pid=$(current_pid)
  if [ -n "$pid" ]; then
    echo "既に起動中 (PID $pid)。停止するには: $0 stop" >&2
    exit 1
  fi

  if [ "$DO_BUILD" -eq 1 ]; then
    build_project
  else
    echo "--- ビルドスキップ (--no-build)"
  fi

  install_to_applications

  echo ""
  echo "APP : $INSTALLED_APP"
  echo "LOG : $LOG"
  echo "PORT: $PORT  (CAPTIONCRAFT_AGENT_MODE=$MODE)"

  launchctl setenv CAPTIONCRAFT_E2E_PORT "$PORT"
  launchctl setenv CAPTIONCRAFT_AGENT_MODE "$MODE"
  launchctl setenv CAPTIONCRAFT_LOG "$LOG"
  if [ -n "$OPEN_FILE" ]; then
    echo "OPEN: $OPEN_FILE"
    open -n "$INSTALLED_APP" --args "$OPEN_FILE"
  else
    open -n "$INSTALLED_APP"
  fi

  sleep 1
  local new_pid
  new_pid=$(current_pid || true)
  if kill -0 "${new_pid:-0}" 2>/dev/null; then
    echo "起動成功: PID $new_pid"
    echo "--- log (先頭 5 行) ---"
    head -5 "$LOG" 2>/dev/null || true
  else
    echo "起動失敗 --- ログ末尾:" >&2
    tail -20 "$LOG" >&2 || true
    exit 1
  fi
}

status() {
  local pid
  pid=$(current_pid)
  if [ -z "$pid" ]; then
    echo "停止中"
    return 0
  fi
  echo "稼働中: PID $pid"
  ps -p "$pid" -o command= 2>/dev/null | head -1
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$PORT" -sTCP:LISTEN -nP 2>/dev/null | head -5 || true
  fi
}

case "$SUBCMD" in
  start)   start ;;
  stop)    stop_existing ;;
  restart) stop_existing; start ;;
  status)  status ;;
  install) install_to_applications ;;
  *)
    echo "使い方: $0 [start|stop|restart|status|install] [--clean] [--no-build]" >&2
    exit 1
    ;;
esac
