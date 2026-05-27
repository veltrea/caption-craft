import Foundation

// MARK: - WordTiming

/// 単語単位のタイムスタンプ (WhisperKit の wordTimestamps=true で得られる)。
/// 自然な単語境界での字幕分割に使う。
struct WordTiming: Equatable {
    let word: String
    let startMs: Int
    let endMs: Int
}

// MARK: - RawTranscriptionSegment

/// Whisper エンジンからの生 segment 表現 (SDK 型に依存しない軽量 struct)。
/// `CaptionTranscriber` が WhisperKit / whisper.cpp の segment 型から変換してここに渡す。
/// これにより `CaptionSegmenter` は Whisper SDK に依存せず、純粋ロジックのまま単体テスト可能。
struct RawTranscriptionSegment: Equatable {
    let text: String
    let startMs: Int
    let endMs: Int
    /// 信頼度 0–1 (任意。0 を渡せば未使用扱い)。
    var confidence: Double = 1.0
    /// 単語単位のタイムスタンプ。nil の場合は segment 全体としてしか扱えない。
    /// WhisperKit (wordTimestamps=true) で取得できる。Parakeet は現状非対応。
    var words: [WordTiming]? = nil
}

// MARK: - CaptionSegmenter

/// Whisper の生 segment 列を、CaptionCraft の仕様に沿って再分割するピュアロジック。
///
/// 成熟度: experimental (FIX_10 Phase 1)
///
/// 仕様 (FIX_10 §8):
/// 1. 句点 (`。?!？！`) で分割 — Whisper segment 内の文字位置を線形補間してタイムスタンプ付与
/// 2. 無音区間 (segment 間 gap が `silenceSplitMs` 以上) で分割
///    — 無音境界は merge しない strict boundary として尊重
/// 3. duration が `minSegmentMs` 未満なら前後に merge (無音境界は跨がない)
/// 4. Whisper の標準 segment 境界は split 条件として使わない
///    (日本語で不安定なため、一旦フラット化してから 1/2 で再分割する)
///
/// この型は副作用なし・SDK 非依存。外部から `resegment(_:settings:)` のみが呼ばれる想定。
enum CaptionSegmenter {

    /// Whisper 生 segment 列を再分割して CaptionRegion 列を返す。
    ///
    /// - Parameters:
    ///   - raw: Whisper エンジンから得た生 segment 列 (時間順で渡すこと)
    ///   - settings: 分割・merge 閾値
    ///   - language: 新規 CaptionRegion に設定する ISO 639-1 言語コード
    /// - Returns: 分割後の CaptionRegion 配列 (時間順)
    static func resegment(
        raw: [RawTranscriptionSegment],
        settings: CaptionSettings,
        language: String
    ) -> [CaptionRegion] {
        guard !raw.isEmpty else { return [] }

        // Step 1: 無音区間で chunk に分ける (跨がない境界)。
        // 各 chunk は「連続して Whisper が発話した塊」。chunk 内だけで分割を行い、
        // chunk を跨ぐ merge は禁止する。
        let chunks = splitBySilence(raw: raw, silenceThresholdMs: settings.silenceSplitMs)

        var result: [CaptionRegion] = []
        for chunk in chunks {
            // 単語タイムスタンプが揃っている chunk は word-aware パスを使う。
            // (Whisper の wordTimestamps=true で取得できる場合)
            // それ以外はレガシーの char-level interpolation パスにフォールバック。
            let allWords = chunk.flatMap { $0.words ?? [] }
            let hasWordTimings = !allWords.isEmpty && chunk.allSatisfy { ($0.words?.isEmpty == false) }
            if hasWordTimings {
                let regions = segmentByWordTimings(
                    chunk: chunk,
                    words: allWords,
                    settings: settings,
                    language: language
                )
                result.append(contentsOf: regions)
            } else {
                let split = splitByPunctuation(chunk: chunk, language: language)
                let smoothed = smooth(regions: split, minSegmentMs: settings.minSegmentMs)
                let wordSplit = splitByWordCount(
                    regions: smoothed,
                    maxWords: settings.maxWordsPerSegment,
                    language: language
                )
                result.append(contentsOf: wordSplit)
            }
        }
        return result
    }

    // MARK: - Word-timing based segmentation (主パス)

    /// 単語タイムスタンプを使って自然な境界で字幕を分割する。
    ///
    /// 分割条件 (優先順位順):
    /// 1. 文末記号 (`。？！?!`) で終わる単語 → 強制分割
    /// 2. 単語数が maxWords を超えていて、かつ次の単語との gap が一定以上 (>=150ms)
    ///    → その位置で分割 (自然な息継ぎで切る)
    /// 3. 次の単語との gap が大きい (>=600ms) → 強制分割 (溜まりすぎ防止)
    /// 4. 単語数が maxWords * 1.5 を超えたら、gap に関係なく分割 (安全弁)
    static func segmentByWordTimings(
        chunk: [RawTranscriptionSegment],
        words: [WordTiming],
        settings: CaptionSettings,
        language: String
    ) -> [CaptionRegion] {
        guard !words.isEmpty else { return [] }

        // CJK は単語数の上限を緩める (1文字 1 単語扱いで偽の上限になるため)
        let cjk: Set<String> = ["ja", "zh", "ko"]
        let isCJK = cjk.contains(language)
        let maxWords = settings.maxWordsPerSegment
        let softLimit = isCJK ? maxWords * 10 : maxWords
        let hardLimit = isCJK ? maxWords * 15 : Int(Double(maxWords) * 1.5)
        let pauseSoftMs = 150
        let pauseHardMs = 600

        // 平均 confidence を chunk 全体から計算 (各 region に同じ値を入れる)
        let avgConf: Double
        if !chunk.isEmpty {
            avgConf = chunk.reduce(0.0) { $0 + $1.confidence } / Double(chunk.count)
        } else {
            avgConf = 1.0
        }

        var regions: [CaptionRegion] = []
        var bufferWords: [WordTiming] = []

        func flushBuffer() {
            guard !bufferWords.isEmpty else { return }
            let text = joinWords(bufferWords, language: language)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                bufferWords.removeAll()
                return
            }
            let startMs = bufferWords.first!.startMs
            let endMs = max(startMs + 1, bufferWords.last!.endMs)
            regions.append(CaptionRegion(
                startMs: startMs,
                endMs: endMs,
                text: trimmed,
                isManuallyEdited: false,
                sourceLanguage: language,
                confidence: avgConf
            ))
            bufferWords.removeAll()
        }

        for (i, w) in words.enumerated() {
            bufferWords.append(w)

            // 1. 文末記号で強制分割
            let trimmed = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = trimmed.last, sentenceTerminators.contains(last) {
                flushBuffer()
                continue
            }

            // 2. 次の単語との gap を見て分割判定
            let isLast = (i == words.count - 1)
            if isLast {
                flushBuffer()
                continue
            }
            let nextStart = words[i + 1].startMs
            let gapMs = nextStart - w.endMs

            // 4. 安全弁: 単語数が hardLimit を超えたら強制
            if bufferWords.count >= hardLimit {
                flushBuffer()
                continue
            }
            // 3. gap が大きい → 強制分割
            if gapMs >= pauseHardMs {
                flushBuffer()
                continue
            }
            // 2. softLimit 超過 + gap がそれなりにあれば分割
            if bufferWords.count >= softLimit && gapMs >= pauseSoftMs {
                flushBuffer()
                continue
            }
        }
        flushBuffer()

        // smooth: 短すぎる region は前後にマージ (無音境界は跨がない前提)
        return smooth(regions: regions, minSegmentMs: settings.minSegmentMs)
    }

    /// 単語列を 1 つの文字列に結合する。CJK 言語は空白なし、その他は半角空白区切り。
    private static func joinWords(_ words: [WordTiming], language: String) -> String {
        let cjk: Set<String> = ["ja", "zh", "ko"]
        if cjk.contains(language) {
            return words.map { $0.word }.joined()
        }
        // WhisperKit の word には先頭の半角空白が含まれる場合がある (例: " hello")。
        // joined(separator:) で二重空白を作らないよう trim してから結合。
        return words
            .map { $0.word.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Step 1: silence-based chunking

    /// 無音区間 (gap >= threshold) を境界として segment 列を chunk に分割。
    /// 返り値の chunk は「時間的に連続した segment 群」。
    static func splitBySilence(
        raw: [RawTranscriptionSegment],
        silenceThresholdMs: Int
    ) -> [[RawTranscriptionSegment]] {
        var chunks: [[RawTranscriptionSegment]] = []
        var current: [RawTranscriptionSegment] = []

        for seg in raw {
            if let last = current.last {
                let gap = seg.startMs - last.endMs
                if gap >= silenceThresholdMs {
                    chunks.append(current)
                    current = [seg]
                    continue
                }
            }
            current.append(seg)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Step 2: punctuation split within a chunk

    /// 日本語/英語の終端記号。
    private static let sentenceTerminators: Set<Character> = ["。", "？", "！", "?", "!"]

    /// chunk 内の segment 群を「テキスト連結 + 文字単位タイムスタンプ線形補間」で
    /// フラット化してから、句点位置で CaptionRegion を生成する。
    static func splitByPunctuation(
        chunk: [RawTranscriptionSegment],
        language: String
    ) -> [CaptionRegion] {
        guard !chunk.isEmpty else { return [] }

        // 各 segment 内で文字ごとにタイムスタンプを線形補間する。
        // char[i] の時刻 = seg.startMs + (seg.endMs - seg.startMs) * (i / count)
        struct TimedChar { let ch: Character; let tMs: Int }
        var timed: [TimedChar] = []
        var avgConfidenceAccum: Double = 0
        var confCount: Int = 0

        for seg in chunk {
            let trimmed = seg.text.trimmingCharacters(in: .whitespaces)
            let chars = Array(trimmed)
            let count = chars.count
            let dur = max(1, seg.endMs - seg.startMs)
            if count == 0 { continue }
            // セグメント間にスペースを挿入（英語等のスペース区切り言語で文が連結するのを防ぐ）
            if !timed.isEmpty,
               let lastCh = timed.last?.ch,
               !lastCh.isWhitespace,
               let firstCh = chars.first,
               !firstCh.isWhitespace {
                timed.append(TimedChar(ch: " ", tMs: seg.startMs))
            }
            for (i, ch) in chars.enumerated() {
                let t = seg.startMs + Int(Double(dur) * Double(i) / Double(count))
                timed.append(TimedChar(ch: ch, tMs: t))
            }
            avgConfidenceAccum += seg.confidence
            confCount += 1
        }
        guard !timed.isEmpty else { return [] }
        let avgConfidence = confCount > 0 ? avgConfidenceAccum / Double(confCount) : 1.0

        // 句点位置で区切る。句点は直前の region に含める (日本語字幕の慣習)。
        var regions: [CaptionRegion] = []
        var bufferChars: [Character] = []
        var bufferStartMs: Int = timed.first!.tMs

        func flush(endMs: Int) {
            let text = String(bufferChars).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                bufferChars.removeAll()
                return
            }
            let region = CaptionRegion(
                startMs: bufferStartMs,
                endMs: max(bufferStartMs + 1, endMs),
                text: text,
                isManuallyEdited: false,
                sourceLanguage: language,
                confidence: avgConfidence
            )
            regions.append(region)
            bufferChars.removeAll()
        }

        for (idx, tc) in timed.enumerated() {
            if bufferChars.isEmpty { bufferStartMs = tc.tMs }
            bufferChars.append(tc.ch)
            if sentenceTerminators.contains(tc.ch) {
                // chunk の最後の文字の endMs まで、あるいは次の文字の tMs の直前まで。
                let endMs = idx + 1 < timed.count ? timed[idx + 1].tMs : chunk.last!.endMs
                flush(endMs: endMs)
            }
        }
        // 末尾に句点なしで残った分。
        if !bufferChars.isEmpty {
            flush(endMs: chunk.last!.endMs)
        }

        // 句点なし chunk の場合、1 つだけ大きな region になるので chunk の境界で合わせる。
        return regions
    }

    // MARK: - Step 3: smoothing (merge too-short segments within a chunk)

    /// chunk 内で duration < minSegmentMs の region を前または後ろに merge する。
    /// 無音境界を跨ぐ merge は呼び出し側で既に chunk 分割しているため禁止済み。
    static func smooth(regions: [CaptionRegion], minSegmentMs: Int) -> [CaptionRegion] {
        guard regions.count > 1 else { return regions }
        var result: [CaptionRegion] = []
        for r in regions {
            let dur = r.endMs - r.startMs
            if dur < minSegmentMs, var last = result.last {
                // 前に merge (無音境界は跨がない前提)。
                last.text = mergeText(last.text, r.text)
                last.endMs = r.endMs
                last.confidence = (last.confidence + r.confidence) / 2.0
                result[result.count - 1] = last
            } else {
                result.append(r)
            }
        }
        // 先頭 region が短い場合: 先頭のみ「後ろに merge」が必要だが、
        // 上のループで前が居なければ append されている。最初の region が短くて
        // 後ろが存在するならそちらに merge する。
        if let first = result.first, (first.endMs - first.startMs) < minSegmentMs, result.count > 1 {
            var next = result[1]
            next.text = mergeText(first.text, next.text)
            next.startMs = first.startMs
            next.confidence = (first.confidence + next.confidence) / 2.0
            result[1] = next
            result.removeFirst()
        }
        return result
    }

    // MARK: - Step 4: word-count split for space-delimited languages

    /// CJK (日本語/中国語/韓国語) 以外の言語で、maxWords を超える region を
    /// 空白境界で分割する。時間は単語数に比例して線形配分する。
    ///
    /// なぜ必要か:
    /// - 英語の `.` (ピリオド) は略語 ("Mr.", "U.S.") や小数 ("3.14") と曖昧なため、
    ///   `splitByPunctuation` の終端記号に含められない。
    /// - 結果として英語音声では chunk 全体が 1 region に吸われて
    ///   `CaptionOverlayView.lineLimit(2)` で切り捨てられる。
    /// - 字幕の慣習として英語は 1 枚 ~10 単語程度に収めるのが読みやすい。
    static func splitByWordCount(
        regions: [CaptionRegion],
        maxWords: Int,
        language: String
    ) -> [CaptionRegion] {
        let cjk: Set<String> = ["ja", "zh", "ko"]
        if cjk.contains(language) || maxWords <= 0 { return regions }

        var result: [CaptionRegion] = []
        for r in regions {
            let words = r.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if words.count <= maxWords {
                result.append(r)
                continue
            }

            // chunk を均等割にする (端数を抱え込まないよう ceil ベースで chunk 数を決める)。
            let chunkCount = Int((Double(words.count) / Double(maxWords)).rounded(.up))
            let wordsPerChunk = Int((Double(words.count) / Double(chunkCount)).rounded(.up))
            let totalDur = max(1, r.endMs - r.startMs)
            let wordCount = words.count

            var idx = 0
            var chunkStartMs = r.startMs
            while idx < wordCount {
                let end = min(idx + wordsPerChunk, wordCount)
                let slice = words[idx..<end].joined(separator: " ")
                let chunkEndMs: Int
                if end == wordCount {
                    chunkEndMs = r.endMs
                } else {
                    // 単語位置に比例した時刻。
                    let ratio = Double(end) / Double(wordCount)
                    chunkEndMs = r.startMs + Int(Double(totalDur) * ratio)
                }
                result.append(CaptionRegion(
                    id: UUID(),
                    startMs: chunkStartMs,
                    endMs: max(chunkStartMs + 1, chunkEndMs),
                    text: slice,
                    isManuallyEdited: r.isManuallyEdited,
                    sourceLanguage: r.sourceLanguage,
                    confidence: r.confidence
                ))
                chunkStartMs = chunkEndMs
                idx = end
            }
        }
        return result
    }

    // MARK: - Step 5: split over-long regions by duration

    /// 書き起こし完了後に、時間が長すぎるリージョンを自動分割する。
    /// VAD が息継ぎなしの長大な発話区間を 1 塊で返した場合のポスト処理。
    ///
    /// - Parameters:
    ///   - regions: 分割対象のリージョン列
    ///   - maxDurationMs: この ms を超えるリージョンを分割する (デフォルト 8000ms)
    ///   - maxWords: 非 CJK 言語での 1 字幕あたり最大単語数
    /// - Returns: 分割後のリージョン列
    static func splitLongRegions(
        _ regions: [CaptionRegion],
        maxDurationMs: Int = 8000,
        maxWords: Int = 10
    ) -> [CaptionRegion] {
        var result: [CaptionRegion] = []
        for r in regions {
            let duration = r.endMs - r.startMs
            if duration <= maxDurationMs || r.text.isEmpty {
                result.append(r)
                continue
            }

            let lang = r.sourceLanguage
            let cjk: Set<String> = ["ja", "zh", "ko"]

            if cjk.contains(lang) {
                // CJK: 句読点で分割を試み、なければ文字数で均等分割
                let splits = splitCJKByPunctuation(r, maxDurationMs: maxDurationMs)
                result.append(contentsOf: splits)
            } else {
                // 非 CJK: 単語数で均等分割
                let splits = splitByWordCountSingle(r, maxWords: maxWords)
                result.append(contentsOf: splits)
            }
        }
        return result
    }

    /// CJK リージョンを句読点で分割する。分割後もまだ長いものは文字数均等割。
    private static func splitCJKByPunctuation(
        _ region: CaptionRegion,
        maxDurationMs: Int
    ) -> [CaptionRegion] {
        let punctuation: Set<Character> = ["。", "、", "？", "！", "，", ".", "?", "!", ","]
        let text = region.text
        let totalDur = max(1, region.endMs - region.startMs)
        let totalChars = text.count
        guard totalChars > 0 else { return [region] }

        // 句読点位置でテキストを分割
        var segments: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if punctuation.contains(ch) {
                segments.append(current)
                current = ""
            }
        }
        if !current.isEmpty { segments.append(current) }

        // 1 分割しかない（句読点なし）→ 文字数均等割
        if segments.count <= 1 {
            return splitByCharCount(region, maxChars: max(1, totalChars * maxDurationMs / totalDur))
        }

        // 各分割に時間を按分
        var regions: [CaptionRegion] = []
        var charOffset = 0
        for seg in segments {
            let trimmed = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                charOffset += seg.count
                continue
            }
            let startRatio = Double(charOffset) / Double(totalChars)
            let endRatio = Double(charOffset + seg.count) / Double(totalChars)
            let startMs = region.startMs + Int(Double(totalDur) * startRatio)
            let endMs = region.startMs + Int(Double(totalDur) * endRatio)

            var r = CaptionRegion(
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: trimmed,
                isManuallyEdited: region.isManuallyEdited,
                sourceLanguage: region.sourceLanguage,
                confidence: region.confidence
            )
            regions.append(r)
            charOffset += seg.count
        }

        // 分割後もまだ長いものがあれば再帰的に文字数分割
        var final: [CaptionRegion] = []
        for r in regions {
            if (r.endMs - r.startMs) > maxDurationMs {
                let maxChars = max(10, r.text.count * maxDurationMs / max(1, r.endMs - r.startMs))
                final.append(contentsOf: splitByCharCount(r, maxChars: maxChars))
            } else {
                final.append(r)
            }
        }
        return final
    }

    /// CJK 向け: 文字数で均等分割。
    private static func splitByCharCount(_ region: CaptionRegion, maxChars: Int) -> [CaptionRegion] {
        let text = region.text
        let chars = Array(text)
        let totalChars = chars.count
        guard totalChars > maxChars && maxChars > 0 else { return [region] }

        let chunkCount = Int((Double(totalChars) / Double(maxChars)).rounded(.up))
        let charsPerChunk = Int((Double(totalChars) / Double(chunkCount)).rounded(.up))
        let totalDur = max(1, region.endMs - region.startMs)

        var results: [CaptionRegion] = []
        var idx = 0
        while idx < totalChars {
            let end = min(idx + charsPerChunk, totalChars)
            let slice = String(chars[idx..<end])
            let startMs = region.startMs + Int(Double(totalDur) * Double(idx) / Double(totalChars))
            let endMs: Int
            if end == totalChars {
                endMs = region.endMs
            } else {
                endMs = region.startMs + Int(Double(totalDur) * Double(end) / Double(totalChars))
            }
            results.append(CaptionRegion(
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: slice.trimmingCharacters(in: .whitespacesAndNewlines),
                isManuallyEdited: region.isManuallyEdited,
                sourceLanguage: region.sourceLanguage,
                confidence: region.confidence
            ))
            idx = end
        }
        return results
    }

    /// 非 CJK 向け: 単語数で均等分割 (1 リージョンに対して適用)。
    private static func splitByWordCountSingle(_ region: CaptionRegion, maxWords: Int) -> [CaptionRegion] {
        let words = region.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > maxWords else { return [region] }

        let chunkCount = Int((Double(words.count) / Double(maxWords)).rounded(.up))
        let wordsPerChunk = Int((Double(words.count) / Double(chunkCount)).rounded(.up))
        let totalDur = max(1, region.endMs - region.startMs)
        let wordCount = words.count

        var results: [CaptionRegion] = []
        var idx = 0
        var chunkStartMs = region.startMs
        while idx < wordCount {
            let end = min(idx + wordsPerChunk, wordCount)
            let slice = words[idx..<end].joined(separator: " ")
            let chunkEndMs: Int
            if end == wordCount {
                chunkEndMs = region.endMs
            } else {
                chunkEndMs = region.startMs + Int(Double(totalDur) * Double(end) / Double(wordCount))
            }
            results.append(CaptionRegion(
                startMs: chunkStartMs,
                endMs: max(chunkStartMs + 1, chunkEndMs),
                text: slice,
                isManuallyEdited: region.isManuallyEdited,
                sourceLanguage: region.sourceLanguage,
                confidence: region.confidence
            ))
            chunkStartMs = chunkEndMs
            idx = end
        }
        return results
    }

    /// 2 つのテキストを自然に連結��る。日本語は空白なし、英語は間に半角空白。
    private static func mergeText(_ a: String, _ b: String) -> String {
        let at = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let bt = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if at.isEmpty { return bt }
        if bt.isEmpty { return at }
        // a の末尾が ASCII (英数 or 句読点) なら空白あり、さもなくば空白なし。
        if let last = at.unicodeScalars.last, last.isASCII {
            return at + " " + bt
        }
        return at + bt
    }
}
