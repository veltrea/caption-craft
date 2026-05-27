import Foundation

// MARK: - DictionaryCorrector

/// 辞書ベースの字幕校正。純粋関数。
/// 辞書エントリの wrong → correct 置換を全 region に適用し、CorrectionRecord を生成する。
///
/// 成熟度: experimental
enum DictionaryCorrector {

    static func intent() -> String {
        """
        役割: CorrectionDictionary のエントリを CaptionRegion 配列に一括適用する純粋関数。
              副作用なし。swift test で単体テスト可能。
        成熟度: experimental
        依存: CaptionRegion, CorrectionDictionary, CorrectionRecord
        変更時の注意: 置換ロジックを変えると校正結果が変わる。テストケースを必ず更新。
        """
    }

    /// 辞書の全エントリを regions に適用する。
    /// - Returns: 校正済み regions。変更があった region には CorrectionRecord が追加され、
    ///   originalRawText が未設定なら書き起こし原文を保存する。
    static func apply(
        dictionary: CorrectionDictionary,
        to regions: [CaptionRegion]
    ) -> (regions: [CaptionRegion], appliedEntryIDs: Set<UUID>) {
        guard !dictionary.entries.isEmpty else { return (regions, []) }

        var result: [CaptionRegion] = []
        var appliedIDs: Set<UUID> = []

        for region in regions {
            var updated = region
            let originalText = region.text

            // originalRawText が未設定なら保存
            if updated.originalRawText == nil {
                updated.originalRawText = originalText
            }

            var currentText = originalText

            for entry in dictionary.entries {
                let replaced = replaceOccurrences(
                    in: currentText,
                    of: entry.wrong,
                    with: entry.correct,
                    caseSensitive: entry.caseSensitive
                )

                if replaced != currentText {
                    appliedIDs.insert(entry.id)
                    currentText = replaced
                }
            }

            if currentText != originalText {
                updated.text = currentText
                updated.corrections.append(CorrectionRecord(
                    regionID: region.id,
                    originalText: originalText,
                    correctedText: currentText,
                    source: .dictionary
                ))
            }

            result.append(updated)
        }

        return (result, appliedIDs)
    }

    /// 全 region から特定の wrong パターンが含まれる region を検索。
    /// 自動辞書学習の「他にも同じ誤認識がある?」チェック用。
    static func findRegionsContaining(
        wrong: String,
        in regions: [CaptionRegion],
        caseSensitive: Bool = false,
        excludingRegionID: UUID? = nil
    ) -> [CaptionRegion] {
        regions.filter { region in
            if region.id == excludingRegionID { return false }
            if caseSensitive {
                return region.text.contains(wrong)
            } else {
                return region.text.localizedStandardContains(wrong)
            }
        }
    }

    /// 1 つの region に辞書エントリ 1 件を適用する。
    /// 一括置換提案 UI で個別適用するとき用。
    static func applySingle(
        entry: DictionaryEntry,
        to region: CaptionRegion
    ) -> CaptionRegion {
        var updated = region
        let originalText = region.text

        if updated.originalRawText == nil {
            updated.originalRawText = originalText
        }

        let replaced = replaceOccurrences(
            in: originalText,
            of: entry.wrong,
            with: entry.correct,
            caseSensitive: entry.caseSensitive
        )

        if replaced != originalText {
            updated.text = replaced
            updated.corrections.append(CorrectionRecord(
                regionID: region.id,
                originalText: originalText,
                correctedText: replaced,
                source: .dictionary
            ))
        }

        return updated
    }

    // MARK: - Private

    private static func replaceOccurrences(
        in text: String,
        of target: String,
        with replacement: String,
        caseSensitive: Bool
    ) -> String {
        if caseSensitive {
            return text.replacingOccurrences(of: target, with: replacement)
        } else {
            return text.replacingOccurrences(
                of: target,
                with: replacement,
                options: .caseInsensitive
            )
        }
    }
}
