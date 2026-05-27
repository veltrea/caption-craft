#!/bin/bash
# scripts/gen_intent_index.sh
#
# 全 Swift ファイルから static func intent() -> String の戻り値文字列を抽出し、
# プロジェクトルートの INTENT_INDEX.md に集約する。
#
# 用途:
#   - 全クラスの「役割」「成熟度」「触ってはいけない場所」を 1 ページで読める
#   - AI セッションが各クラスの intent を一覧したい時、INTENT_INDEX.md を見れば済む
#   - 自動生成なので、Swift ファイルを更新したら必ず再実行すること
#
# 使い方:
#   bash scripts/gen_intent_index.sh
#   # → ./INTENT_INDEX.md に出力
#
# 制約:
#   - intent() の本体は `return """ ... """` 形式の Swift マルチライン文字列を前提
#   - インデントは 8 スペース (Swift 慣用) を仮定して剥がす

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="docs/INTENT_INDEX.md"

{
    echo "# CaptionCraft — Intent Index"
    echo ""
    echo "**自動生成** — \`scripts/gen_intent_index.sh\` で再生成。手で編集しても次回の生成で上書きされる。"
    echo ""
    echo "**最終生成**: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "---"
    echo ""

    # 全 Swift ファイルを順番に処理 (Resources/ 配下は除外)
    for file in $(find CaptionCraft -name "*.swift" -not -path "*/Resources/*" | sort); do
        # intent() を含むファイルだけ処理
        if grep -q "static func intent" "$file" 2>/dev/null; then
            base=$(basename "$file" .swift)
            relpath="${file#./}"

            echo "## ${base}"
            echo ""
            echo "ファイル: \`${relpath}\`"
            echo ""

            # awk で intent() メソッドのブロックを抽出して、
            # その中の return """ ... """ の中身だけを取り出す
            awk '
                /static func intent\(\) -> String/ { in_intent = 1 }
                in_intent && /return """/ { in_string = 1; next }
                in_intent && in_string && /"""/ { in_string = 0; in_intent = 0; next }
                in_intent && in_string { print }
            ' "$file" | sed 's/^        //'

            echo ""
            echo "---"
            echo ""
        fi
    done
} > "$OUT"

# 統計を末尾に追記
intent_count=$(grep -c "^## " "$OUT" || true)
{
    echo ""
    echo "## 統計"
    echo ""
    echo "- intent() を持つ型: ${intent_count} 件"
} >> "$OUT"

echo "Wrote $OUT (${intent_count} intent entries)"
