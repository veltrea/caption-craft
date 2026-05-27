#!/usr/bin/env bash
# CaptionCraft の公開リポ (veltrea/caption-craft) に GitHub Release を作成する。
#
# 使い方:
#   ./scripts/release.sh                 project.yml のバージョンで release 作成
#   ./scripts/release.sh --clean         DerivedData クリーン込みで DMG 再ビルド
#   ./scripts/release.sh --replace       同名 release が既にあれば DMG を差し替え
#   ./scripts/release.sh --notes "..."   リリースノート本文を指定
#   ./scripts/release.sh --draft         draft として作成 (公開前に手動レビュー)
#
# 動作:
#   1. scripts/make_dmg.sh を呼んで dist/CaptionCraft-<version>.dmg を作成
#   2. 公開リポ veltrea/caption-craft の main ブランチに対して
#      gh release create v<version> --repo veltrea/caption-craft --target main
#      でタグとリリースをまとめて作成、DMG をアセット添付
#   3. --replace 指定時は既存 release の DMG を上書きアップロード
#
# 重要:
#   - 公開リポは scripts/publish-public.sh によるスナップショットしか持たない
#     (ローカル main の git 履歴とは別)。リリース前に publish-public.sh を
#     実行して公開リポを最新ソースに同期しておくこと。
#   - 公開リポは veltrea/caption-craft で固定。プライベートリポ
#     (caption-craft-private = ローカル origin) にはリリースを作らない。
#
# 前提:
#   - gh CLI がログイン済み (アカウント: veltrea)
#   - 公開リポ veltrea/caption-craft が存在する

set -eu

PUBLIC_REPO="veltrea/caption-craft"

DO_CLEAN=0
REPLACE=0
DRAFT=0
NOTES=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --clean)   DO_CLEAN=1 ;;
    --replace) REPLACE=1 ;;
    --draft)   DRAFT=1 ;;
    --notes)   shift; NOTES="$1" ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# バージョン取得
VERSION=$(grep -E "CFBundleShortVersionString" project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
TAG="v$VERSION"
echo "--- target: $PUBLIC_REPO $TAG"

# 公開リポの存在確認
if ! gh repo view "$PUBLIC_REPO" --json name >/dev/null 2>&1; then
  echo "公開リポ $PUBLIC_REPO が見つかりません" >&2
  exit 1
fi

# 公開リポと現状ソースが揃っているかの軽い注意喚起 (強制はしない)
PUB_LATEST=$(gh api "repos/$PUBLIC_REPO/commits/main" --jq '.commit.author.date' 2>/dev/null || echo "unknown")
LOCAL_LATEST=$(git log -1 --format='%ai')
echo "--- 公開リポ main 最終更新: $PUB_LATEST"
echo "--- ローカル main 最終更新: $LOCAL_LATEST"
echo "    (ズレている場合は先に scripts/publish-public.sh を実行)"

# DMG 作成
DMG_ARGS=""
[ "$DO_CLEAN" -eq 1 ] && DMG_ARGS="--clean"
echo "--- DMG 作成"
bash "$ROOT/scripts/make_dmg.sh" $DMG_ARGS

DMG_PATH="$ROOT/dist/CaptionCraft-$VERSION.dmg"
if [ ! -f "$DMG_PATH" ]; then
  echo "DMG が見つかりません: $DMG_PATH" >&2
  exit 1
fi

# 既存リリースの有無
EXISTS=0
gh release view "$TAG" --repo "$PUBLIC_REPO" >/dev/null 2>&1 && EXISTS=1

if [ "$EXISTS" -eq 1 ]; then
  if [ "$REPLACE" -eq 1 ]; then
    echo "--- 既存 release $TAG に DMG を差し替え"
    gh release upload "$TAG" "$DMG_PATH" --repo "$PUBLIC_REPO" --clobber
  else
    echo "release $TAG は $PUBLIC_REPO に既に存在します。差し替えるなら --replace を指定してください" >&2
    exit 1
  fi
else
  echo "--- gh release create $TAG on $PUBLIC_REPO"
  # 公開リポにはローカル commits が無いため、--target main で公開リポ側の
  # main ブランチ HEAD に対してタグを切る。
  CREATE_ARGS=("$TAG" "$DMG_PATH"
    --repo "$PUBLIC_REPO"
    --target main
    --title "CaptionCraft $VERSION")
  [ "$DRAFT" -eq 1 ] && CREATE_ARGS+=(--draft)
  if [ -n "$NOTES" ]; then
    CREATE_ARGS+=(--notes "$NOTES")
  else
    # --generate-notes は同リポ内のコミット履歴ベース。snapshot 履歴しか
    # 無い公開リポでは意味が薄いので、空ノートにしておく。
    CREATE_ARGS+=(--notes "Release $VERSION")
  fi
  gh release create "${CREATE_ARGS[@]}"
fi

echo ""
echo "完了: $PUBLIC_REPO $TAG"
gh release view "$TAG" --repo "$PUBLIC_REPO" --json url -q .url
