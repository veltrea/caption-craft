#!/usr/bin/env bash
# CaptionCraft の TCC 権限をリセットする。
#
# 開発中、ad-hoc 署名 (CODE_SIGN_IDENTITY="-") でビルドするたびに
# バイナリのハッシュが変わり、macOS が「別のアプリ」と判定して権限を無効化する症状を救済する。
#
# 使い方:
#   scripts/reset_tcc.sh          # マイク権限をリセット
#
# リセット後は CaptionCraft を完全終了 (Cmd-Q) してから再起動すること。

set -euo pipefail

BUNDLE_ID="com.veltrea.captioncraft"

echo "--- Microphone をリセット"
tccutil reset Microphone "$BUNDLE_ID" || true

echo ""
echo "完了。CaptionCraft を Cmd-Q で完全終了してから再起動してください。"
