import Foundation

// MARK: - EditDiffExtractor

/// ユーザーの手動編集から修正パターンを抽出する純粋関数。
/// 編集前後のテキストを比較し、辞書登録候補となる差分を返す。
///
/// 成熟度: experimental
enum EditDiffExtractor {

    static func intent() -> String {
        """
        役割: 編集前後のテキスト比較から辞書登録候補 (EditDiff) を抽出する。
              副作用なし。swift test で単体テスト可能。
        成熟度: experimental
        依存: なし (純粋関数)
        変更時の注意: diff 抽出アルゴリズムを変えると自動辞書学習の精度が変わる。
        """
    }

    /// 編集前後から修正パターンを抽出する。
    ///
    /// 戦略: 共通の prefix と suffix を取り除いて、変わった部分だけを抽出する。
    /// 単純だが、「quad code → Claude Code」のような単語レベルの差し替えには十分。
    ///
    /// - Returns: 差分がない場合は nil。差分が大きすぎる (テキストの 80% 以上が変更) 場合も nil
    ///   (全面書き換えは辞書登録に適さない)。
    static func extract(before: String, after: String) -> EditDiff? {
        guard before != after else { return nil }
        guard !before.isEmpty, !after.isEmpty else { return nil }

        let beforeChars = Array(before)
        let afterChars = Array(after)

        // 共通 prefix の長さ
        var prefixLen = 0
        while prefixLen < beforeChars.count
                && prefixLen < afterChars.count
                && beforeChars[prefixLen] == afterChars[prefixLen] {
            prefixLen += 1
        }

        // 共通 suffix の長さ (prefix と重ならない範囲で)
        var suffixLen = 0
        while suffixLen < (beforeChars.count - prefixLen)
                && suffixLen < (afterChars.count - prefixLen)
                && beforeChars[beforeChars.count - 1 - suffixLen] == afterChars[afterChars.count - 1 - suffixLen] {
            suffixLen += 1
        }

        let beforeDiff = String(beforeChars[prefixLen ..< (beforeChars.count - suffixLen)])
        let afterDiff = String(afterChars[prefixLen ..< (afterChars.count - suffixLen)])

        // 差分が空 (片方の挿入/削除のみ) の場合は辞書登録に不向き
        guard !beforeDiff.isEmpty, !afterDiff.isEmpty else { return nil }

        // 差分がテキストの大部分を占める場合はスキップ
        let changeRatio = Double(beforeDiff.count) / Double(before.count)
        guard changeRatio < 0.8 else { return nil }

        // 単語境界に揃える (日本語は不要だが、英語では前後の空白を含めない)
        let trimmedBefore = beforeDiff.trimmingCharacters(in: .whitespaces)
        let trimmedAfter = afterDiff.trimmingCharacters(in: .whitespaces)
        guard !trimmedBefore.isEmpty, !trimmedAfter.isEmpty else { return nil }

        // 周辺コンテキスト (前後 10 文字)
        let contextStart = max(0, prefixLen - 10)
        let contextEnd = min(beforeChars.count, beforeChars.count - suffixLen + 10)
        let context = String(beforeChars[contextStart ..< contextEnd])

        return EditDiff(
            before: trimmedBefore,
            after: trimmedAfter,
            context: context
        )
    }
}

// MARK: - EditDiff

/// 編集による差分 1 件。辞書登録候補。
struct EditDiff {
    /// 変更前の部分文字列 (例: "quad code")。
    let before: String
    /// 変更後の部分文字列 (例: "Claude Code")。
    let after: String
    /// 周辺テキスト (辞書登録時の参考表示)。
    let context: String
}
