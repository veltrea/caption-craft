#!/usr/bin/env bash
# CaptionCraft の配布用 DMG を作成する。
#
# 使い方:
#   ./scripts/make_dmg.sh              Release ビルド + DMG 作成
#   ./scripts/make_dmg.sh --clean      DerivedData をクリアしてから
#
# 出力:
#   dist/CaptionCraft-<version>.dmg
#
# 中身:
#   - CaptionCraft.app  (Release ビルド, ad-hoc 署名)
#   - Applications      (/Applications へのシンボリックリンク)
#
# 注意:
#   Developer ID 署名・notarization は行わない。
#   配布先のユーザーは初回起動時に Gatekeeper の警告に対応する必要がある
#   (右クリック → 開く、または「システム設定 → プライバシーとセキュリティ」で許可)。

set -eu

DO_CLEAN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --clean) DO_CLEAN=1 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST_DIR="$ROOT/dist"
BUILD_LOG="/tmp/cc-dmg-build.log"

# project.yml からバージョン抽出
VERSION=$(grep -E "CFBundleShortVersionString" project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$VERSION" ]; then
  echo "project.yml から CFBundleShortVersionString を取得できませんでした" >&2
  exit 1
fi
echo "--- version: $VERSION"

# pbxproj 再生成
echo "--- xcodegen generate"
xcodegen generate

# DerivedData クリーン
if [ "$DO_CLEAN" -eq 1 ]; then
  echo "--- DerivedData クリーン"
  find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name 'CaptionCraft-*' -exec rm -rf {} + 2>/dev/null || true
fi

# Release ビルド (xcodebuild は ad-hoc 署名で SPM 依存も通る)
echo "--- xcodebuild Release"
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
    -project CaptionCraft.xcodeproj \
    -scheme CaptionCraft \
    -configuration Release \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    build \
    > "$BUILD_LOG" 2>&1
BUILD_EXIT=$?
set -e

if [ "$BUILD_EXIT" -ne 0 ]; then
  echo "--- ビルド失敗 (exit $BUILD_EXIT)"
  grep -E "(error:|BUILD FAILED)" "$BUILD_LOG" | head -50
  echo "--- 詳細ログ: $BUILD_LOG"
  exit "$BUILD_EXIT"
fi
echo "--- ビルド成功"

# Release の .app を特定
SRC_APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/CaptionCraft-*/Build/Products/Release/CaptionCraft.app 2>/dev/null | head -1 || true)
if [ -z "$SRC_APP" ]; then
  echo "Release 版 CaptionCraft.app が見つかりません" >&2
  exit 1
fi
echo "--- source: $SRC_APP"

# DMG ステージング用の一時ディレクトリ
STAGE_DIR=$(mktemp -d /tmp/cc-dmg-stage.XXXXXX)
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "--- ステージング: $STAGE_DIR"
cp -R "$SRC_APP" "$STAGE_DIR/CaptionCraft.app"

# 完全版アイコン差し替え (存在時のみ)
if [ -f /tmp/FullAppIcon.icns ]; then
  echo "--- AppIcon.icns を完全版で差し替え"
  cp -f /tmp/FullAppIcon.icns "$STAGE_DIR/CaptionCraft.app/Contents/Resources/AppIcon.icns"
fi

# ad-hoc 署名で再署名 (内側 dylib → 外側 bundle)
echo "--- ad-hoc 再署名"
for dylib in "$STAGE_DIR/CaptionCraft.app/Contents/MacOS"/*.dylib; do
  [ -f "$dylib" ] && codesign --force --sign - "$dylib" 2>&1 | tail -1
done
codesign --force --deep --sign - "$STAGE_DIR/CaptionCraft.app" 2>&1 | tail -1

# /Applications シンボリックリンク
ln -s /Applications "$STAGE_DIR/Applications"

# DMG 作成
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/CaptionCraft-$VERSION.dmg"
rm -f "$DMG_PATH"

echo "--- DMG 作成: $DMG_PATH"
hdiutil create \
  -volname "CaptionCraft $VERSION" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

# DMG 自体にも ad-hoc 署名 (Gatekeeper のフットプリント低減)
codesign --force --sign - "$DMG_PATH" 2>&1 | tail -1 || true

SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo ""
echo "完了: $DMG_PATH ($SIZE)"
