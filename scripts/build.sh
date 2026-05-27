#!/usr/bin/env bash
# CaptionCraft をビルドする (起動はしない)。
#
# 使い方:
#   ./scripts/build.sh             Debug ビルド
#   ./scripts/build.sh --clean     DerivedData を削除してからフルビルド
#   ./scripts/build.sh --release   Release 構成でビルド
#
# 起動も含めて行いたい場合は ./scripts/run.sh を使うこと。
#
# 署名:
#   WhisperKit の SPM 依存 (swift-crypto / swift-transformers) が要求する
#   署名仕様と本体の Local Dev cert を両立するため、xcodebuild 段階では
#   ad-hoc (`-`) で通す。本体 .app への Local Dev cert 貼り直しは
#   run.sh の install ステップで行う (本 script はビルドのみ)。

set -eu
cd "$(dirname "$0")/.."

# --- フラグ解析
DO_CLEAN=0
CONFIG="Debug"
for arg in "$@"; do
  case "$arg" in
    --clean)   DO_CLEAN=1 ;;
    --release) CONFIG="Release" ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

BUILD_LOG="/tmp/cc-build.log"

# --- DerivedData クリーン (フルクリーン時のみ)
if [ "$DO_CLEAN" -eq 1 ]; then
  echo "--- DerivedData クリーン (CaptionCraft-*)"
  find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d \
    -name 'CaptionCraft-*' -exec rm -rf {} + 2>/dev/null || true
fi

# --- pbxproj 再生成 (新規 Swift ファイル追加対応)
echo "--- xcodegen generate"
xcodegen generate

# --- xcodebuild 実行
ACTION="build"
[ "$DO_CLEAN" -eq 1 ] && ACTION="clean build"
echo "--- xcodebuild $ACTION ($CONFIG)"

set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
    -project CaptionCraft.xcodeproj \
    -scheme CaptionCraft \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    $ACTION \
    > "$BUILD_LOG" 2>&1
BUILD_EXIT=$?
set -e

# --- 結果
if [ "$BUILD_EXIT" -ne 0 ]; then
  echo "--- ビルド失敗 (exit $BUILD_EXIT)"
  echo "--- エラー行抽出:"
  grep -E "(error:|BUILD FAILED)" "$BUILD_LOG" | head -50
  echo ""
  echo "--- 詳細ログ: $BUILD_LOG"
  exit "$BUILD_EXIT"
fi

WARN_COUNT=$(grep -cE 'warning:' "$BUILD_LOG" 2>/dev/null || echo 0)
echo "--- ビルド成功 (warnings: $WARN_COUNT)"
echo ""
echo "起動するには: ./scripts/run.sh"
