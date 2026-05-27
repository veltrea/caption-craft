#!/bin/bash
# scripts/check_intent.sh
#
# 全 Swift ファイルから class/struct/enum 定義を抽出し、同ファイル内に
# `static func intent() -> String` があるか確認する lint スクリプト。
#
# 用途:
#   - 開発中: 手動で実行して未実装ファイルを見つける
#   - CI: INTENT_STRICT=1 で 1 件でも未実装ならエラー終了
#
# 使い方:
#   bash scripts/check_intent.sh           # warning だけ出して終了コード 0
#   INTENT_STRICT=1 bash scripts/check_intent.sh   # 1 件でもなければ exit 1
#
# 対象外:
#   - private / fileprivate な型 (外部から見えないので意味がない)
#   - Resources/ 配下 (JSON など、Swift 以外の意図しない混入を避ける)

set -euo pipefail
cd "$(dirname "$0")/.."

missing_total=0
files_checked=0

for file in $(find CaptionCraft -name "*.swift" -not -path "*/Resources/*"); do
    files_checked=$((files_checked + 1))

    # public/internal/(暗黙の internal) な型定義を数える
    # private / fileprivate は除外
    types=$(grep -E "^(public |internal |open |final )?(class|struct|enum) " "$file" | wc -l | tr -d ' ')

    # static func intent() -> String の出現数
    intents=$(grep -E "static func intent\(\) -> String" "$file" | wc -l | tr -d ' ')

    if [ "$types" -gt 0 ] && [ "$intents" -lt "$types" ]; then
        missing=$((types - intents))
        echo "warning: $file — $types public type(s), $intents intent() (missing: $missing)"
        missing_total=$((missing_total + missing))
    fi
done

echo ""
echo "=== check_intent.sh summary ==="
echo "Files checked: $files_checked"
echo "Missing intent(): $missing_total"

if [ "$missing_total" -gt 0 ] && [ "${INTENT_STRICT:-0}" = "1" ]; then
    echo ""
    echo "INTENT_STRICT=1 set, failing build."
    exit 1
fi

exit 0
