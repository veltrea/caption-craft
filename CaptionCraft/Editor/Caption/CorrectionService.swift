import Foundation

// MARK: - CorrectionService

/// LLM ベースの字幕校正サービス。
/// 文脈推定 → LLM 一括校正のパイプラインを駆動する。
///
/// 成熟度: experimental
@MainActor
final class CorrectionService: ObservableObject {

    static func intent() -> String {
        """
        役割: LLM を使った字幕校正パイプラインのオーケストレータ。
              Step 1: 文脈推定 (全文 → ドメイン / 重要語 / 修正候補)
              Step 2: LLM 一括校正 (バッチ単位で校正)
              DictionaryCorrector (辞書ベース置換) は別クラス。
        成熟度: experimental
        依存: LLMClient, CaptionRegion, CorrectionRecord, CorrectionContext
        """
    }

    // MARK: - Published state

    @Published var isRunning: Bool = false
    @Published var progress: String = ""
    @Published var lastError: String?
    @Published var lastContext: CorrectionContext?

    // MARK: - Correction

    /// LLM 校正を実行する。
    /// 1. 全文から文脈を推定
    /// 2. 文脈を踏まえてバッチ校正
    func correct(
        regions: [CaptionRegion],
        domainHints: [String],
        client: LLMClient,
        language: String = "日本語",
        onBatchDone: (([CaptionRegion]) -> Void)? = nil
    ) async throws -> [CaptionRegion] {
        guard !regions.isEmpty else { return [] }

        isRunning = true
        lastError = nil
        progress = L10n.Progress.contextInference
        defer { isRunning = false }

        // Step 1: 文脈推定
        AppLog.caption.info("LLM 校正開始: \(regions.count) regions")
        let context = try await inferContext(
            regions: regions,
            domainHints: domainHints,
            client: client
        )
        lastContext = context
        AppLog.caption.info("文脈推定完了: domain=\(context.domain, privacy: .public) keyTerms=\(context.keyTerms.count)")

        // Step 2: LLM 一括校正
        let batchSize = 20
        var corrected: [CaptionRegion] = []
        var done = 0

        for batchStart in stride(from: 0, to: regions.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, regions.count)
            let batch = Array(regions[batchStart..<batchEnd])

            progress = L10n.Progress.correcting(done: done, total: regions.count)
            let result = try await correctBatch(
                batch: batch,
                context: context,
                client: client,
                language: language
            )
            corrected.append(contentsOf: result)

            done += batch.count
            let remaining = Array(regions[batchEnd...])
            onBatchDone?(corrected + remaining)
        }

        progress = L10n.Progress.done
        AppLog.caption.info("LLM 校正完了: \(corrected.count) regions")
        return corrected
    }

    // MARK: - Single region correction

    /// 1 件だけ LLM 校正する。前後の文脈も含めてバッチに投げる。
    func correctSingle(
        targetIndex: Int,
        allRegions: [CaptionRegion],
        domainHints: [String],
        client: LLMClient
    ) async throws -> CaptionRegion {
        guard targetIndex >= 0 && targetIndex < allRegions.count else {
            return allRegions[targetIndex]
        }

        isRunning = true
        lastError = nil
        progress = L10n.Progress.correctingSingle
        defer { isRunning = false; progress = "" }

        // 前後 2 件ずつ文脈として渡す
        let lo = max(0, targetIndex - 2)
        let hi = min(allRegions.count, targetIndex + 3)
        let contextBatch = Array(allRegions[lo..<hi])

        // domainHints から辞書ペア（"wrong→correct" 形式）を分離
        var pureHints: [String] = []
        var dictSuggestions: [SuggestedCorrection] = []
        for hint in domainHints {
            if let arrowIdx = hint.firstIndex(of: "→") {
                let wrong = String(hint[hint.startIndex..<arrowIdx])
                let correct = String(hint[hint.index(after: arrowIdx)...])
                dictSuggestions.append(SuggestedCorrection(
                    wrong: wrong, correct: correct,
                    confidence: 1.0, reasoning: "辞書登録済み"
                ))
            } else {
                pureHints.append(hint)
            }
        }

        let context = CorrectionContext(
            domain: pureHints.first ?? "",
            keyTerms: pureHints,
            suggestedCorrections: dictSuggestions
        )
        let regionLang = allRegions[targetIndex].sourceLanguage
        let langName = Self.languageDisplayName(regionLang)
        let result = try await correctBatch(
            batch: contextBatch,
            context: context,
            client: client,
            language: langName
        )

        let offsetInBatch = targetIndex - lo
        guard offsetInBatch < result.count else { return allRegions[targetIndex] }
        return result[offsetInBatch]
    }

    // MARK: - Language display name

    private static func languageDisplayName(_ code: String) -> String {
        switch code {
        case "ja": return "日本語"
        case "en": return "English"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "it": return "Italiano"
        case "es": return "Español"
        default: return code
        }
    }

    // MARK: - Step 1: Context Inference

    private func inferContext(
        regions: [CaptionRegion],
        domainHints: [String],
        client: LLMClient
    ) async throws -> CorrectionContext {
        let allText = regions.map(\.text).joined(separator: "\n")
        // 先頭 2000 文字 + 末尾 500 文字
        let truncated: String
        if allText.count <= 2500 {
            truncated = allText
        } else {
            let prefix = String(allText.prefix(2000))
            let suffix = String(allText.suffix(500))
            truncated = prefix + "\n...\n" + suffix
        }

        let hintsStr = domainHints.isEmpty ? "なし" : domainHints.joined(separator: ", ")

        let system = PromptManager.Correction.contextInferenceSystem()
        let user = PromptManager.Correction.contextInferenceUser(
            transcription: truncated,
            hints: hintsStr
        )

        let response = try await client.chatCompletion(
            system: system,
            user: user,
            temperature: 0.2,
            maxTokens: 2048
        )

        return parseContextResponse(response)
    }

    private func parseContextResponse(_ response: String) -> CorrectionContext {
        // JSON 部分を抽出 (LLM が余計なテキストを付けることがある)
        let jsonStr: String
        if let start = response.firstIndex(of: "{"),
           let end = response.lastIndex(of: "}") {
            jsonStr = String(response[start...end])
        } else {
            jsonStr = response
        }

        guard let data = jsonStr.data(using: .utf8) else {
            AppLog.caption.error("\(L10n.Error.contextEncodeFailed, privacy: .public)")
            return CorrectionContext(domain: L10n.Error.contextUnknown, keyTerms: [], suggestedCorrections: [])
        }

        do {
            return try JSONDecoder().decode(CorrectionContext.self, from: data)
        } catch {
            AppLog.caption.error("文脈推定 JSON パース失敗: \(error.localizedDescription, privacy: .public)")
            return CorrectionContext(domain: L10n.Error.contextUnknown, keyTerms: [], suggestedCorrections: [])
        }
    }

    // MARK: - Step 2: Batch Correction

    func correctBatch(
        batch: [CaptionRegion],
        context: CorrectionContext,
        client: LLMClient,
        language: String = "日本語"
    ) async throws -> [CaptionRegion] {
        var inputLines: [String] = []
        for (i, region) in batch.enumerated() {
            inputLines.append("[\(i + 1)] \(region.text)")
        }
        let inputText = inputLines.joined(separator: "\n")

        let termsStr = context.keyTerms.joined(separator: ", ")

        var dictSection = ""
        if !context.suggestedCorrections.isEmpty {
            let pairs = context.suggestedCorrections
                .map { "  「\($0.wrong)」→「\($0.correct)」" }
                .joined(separator: "\n")
            dictSection = "\n\n【辞書（必ず適用）】\n以下の誤認識パターンが登録されています。該当する箇所は必ず修正してください:\n\(pairs)"
        }

        let system = PromptManager.Correction.batchCorrectionSystem(
            domain: context.domain,
            keyTerms: termsStr,
            dictSection: dictSection,
            language: language
        )

        print("[CC-DEBUG] LLM 校正リクエスト送信: batch=\(batch.count)件, endpoint=\(client.endpoint.absoluteString)")
        print("[CC-DEBUG] user input:\n\(inputText)")

        let content = try await client.chatCompletion(
            system: system,
            user: inputText,
            temperature: 0.2,
            maxTokens: batch.count * 200
        )

        print("[CC-DEBUG] LLM 校正レスポンス (raw):\n\(content)")
        return mergeCorrectionResult(original: batch, llmOutput: content)
    }

    /// LLM 出力をパースして校正結果をマージ。
    private func mergeCorrectionResult(
        original: [CaptionRegion],
        llmOutput: String
    ) -> [CaptionRegion] {
        let pattern = /\[(\d+)\]\s*(.*)/
        var correctionMap: [Int: (text: String, changed: Bool)] = [:]

        let lines = llmOutput.components(separatedBy: "\n")
        print("[CC-DEBUG] LLM 出力行数: \(lines.count)")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.firstMatch(of: pattern) {
                if let num = Int(match.1) {
                    var text = String(match.2)
                    let changed = text.hasSuffix("{CHANGED}")
                    if changed {
                        text = text.replacingOccurrences(of: "{CHANGED}", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    }
                    print("[CC-DEBUG] パース結果 [\(num)]: changed=\(changed) text=\"\(text)\"")
                    correctionMap[num] = (text, changed)
                }
            }
        }

        var result: [CaptionRegion] = []
        for (i, region) in original.enumerated() {
            var updated = region
            if let correction = correctionMap[i + 1], correction.changed {
                let originalText = region.text

                // 変更率が高すぎる場合は文書き換えと判断して棄却
                if isExcessiveChange(original: originalText, corrected: correction.text) {
                    AppLog.caption.warning("LLM 校正棄却 (変更率超過): [\(i + 1)] \"\(originalText, privacy: .public)\" → \"\(correction.text, privacy: .public)\"")
                    result.append(updated)
                    continue
                }

                if updated.originalRawText == nil {
                    updated.originalRawText = originalText
                }

                updated.text = correction.text
                updated.corrections.append(CorrectionRecord(
                    regionID: region.id,
                    originalText: originalText,
                    correctedText: correction.text,
                    source: .llm
                ))
            }
            result.append(updated)
        }
        return result
    }

    /// 変更率が閾値を超えているかを判定する。
    /// 単語差し替えなら変更率は低く、文書き換えなら高くなる。
    private func isExcessiveChange(original: String, corrected: String) -> Bool {
        let maxChangeRatio = 0.3

        guard !original.isEmpty else { return false }

        // 共通プレフィックス・サフィックスを除外して差分の文字数を計算
        let origChars = Array(original)
        let corrChars = Array(corrected)

        var prefixLen = 0
        while prefixLen < origChars.count && prefixLen < corrChars.count
                && origChars[prefixLen] == corrChars[prefixLen] {
            prefixLen += 1
        }

        var suffixLen = 0
        while suffixLen < (origChars.count - prefixLen)
                && suffixLen < (corrChars.count - prefixLen)
                && origChars[origChars.count - 1 - suffixLen] == corrChars[corrChars.count - 1 - suffixLen] {
            suffixLen += 1
        }

        let unchangedChars = prefixLen + suffixLen
        let changedChars = max(origChars.count, corrChars.count) - unchangedChars
        let ratio = Double(changedChars) / Double(origChars.count)

        return ratio > maxChangeRatio
    }
}
