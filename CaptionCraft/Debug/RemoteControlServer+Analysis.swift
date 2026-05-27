import AppKit
import Foundation

// MARK: - ACP 分析・可視化

extension RemoteControlServer {

    // MARK: GET /screenshot

    func handleGetScreenshot() -> HTTPResponse {
        guard let window = editorWindow?.window,
              let contentView = window.contentView else {
            return errorResponse("503 Service Unavailable", "no editor window")
        }

        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return errorResponse("500 Internal Server Error", "screenshot capture failed")
        }
        contentView.cacheDisplay(in: bounds, to: rep)

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return errorResponse("500 Internal Server Error", "PNG conversion failed")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("captioncraft-screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime]
        let filename = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-") + ".png"
        let fileURL = dir.appendingPathComponent(filename)

        do {
            try pngData.write(to: fileURL)
        } catch {
            return errorResponse("500 Internal Server Error", "write failed: \(error.localizedDescription)")
        }

        let json: [String: Any] = [
            "ok": true,
            "path": fileURL.path,
            "width": Int(bounds.width),
            "height": Int(bounds.height)
        ]
        let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return HTTPResponse(status: "200 OK", body: body)
    }

    // MARK: GET /statistics

    func handleGetStatistics() -> HTTPResponse {
        guard let state = store?.project?.editor else {
            return errorResponse("503 Service Unavailable", "no project open")
        }
        let regions = state.captionRegions

        var byLanguage: [String: Int] = [:]
        var totalConfidence = 0.0
        var emptyCount = 0
        var shortCount = 0
        var lowConfidenceCount = 0
        var translatedCount = 0
        var correctedCount = 0
        var totalDurationMs = 0
        var manuallyEditedCount = 0

        for r in regions {
            byLanguage[r.sourceLanguage, default: 0] += 1
            totalConfidence += r.confidence
            if r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emptyCount += 1 }
            let dur = r.endMs - r.startMs
            totalDurationMs += dur
            if dur < 300 { shortCount += 1 }
            if r.confidence < 0.6 { lowConfidenceCount += 1 }
            if r.translatedText != nil { translatedCount += 1 }
            if !r.corrections.isEmpty { correctedCount += 1 }
            if r.isManuallyEdited { manuallyEditedCount += 1 }
        }

        let stats = ACPStatistics(
            totalRegions: regions.count,
            byLanguage: byLanguage,
            avgConfidence: regions.isEmpty ? 0 : totalConfidence / Double(regions.count),
            emptyCount: emptyCount,
            shortCount: shortCount,
            lowConfidenceCount: lowConfidenceCount,
            translatedCount: translatedCount,
            correctedCount: correctedCount,
            totalDurationMs: totalDurationMs,
            manuallyEditedCount: manuallyEditedCount
        )
        return encodableResponse(stats)
    }

    // MARK: GET /problems

    func handleGetProblems(path: String) -> HTTPResponse {
        guard let state = store?.project?.editor else {
            return errorResponse("503 Service Unavailable", "no project open")
        }
        let regions = state.captionRegions
        let query = parseQuery(path)
        let threshold = Double(query["threshold"] ?? "") ?? 0.6

        var lowConfidence: [ACPProblemRegion] = []
        var empty: [ACPProblemRegion] = []
        var tooShort: [ACPProblemRegion] = []

        for (i, r) in regions.enumerated() {
            let pr = { (reason: String) in
                ACPProblemRegion(
                    index: i, startMs: r.startMs, endMs: r.endMs,
                    text: r.text, confidence: r.confidence,
                    sourceLanguage: r.sourceLanguage, reason: reason
                )
            }
            if r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                empty.append(pr("empty text"))
            }
            if r.confidence < threshold {
                lowConfidence.append(pr("confidence \(String(format: "%.2f", r.confidence)) < \(String(format: "%.2f", threshold))"))
            }
            if (r.endMs - r.startMs) < 300 {
                tooShort.append(pr("duration \(r.endMs - r.startMs)ms < 300ms"))
            }
        }

        let problems = ACPProblems(
            lowConfidence: lowConfidence, empty: empty, tooShort: tooShort
        )
        return encodableResponse(problems)
    }

    // MARK: GET /diff

    func handleGetDiff(path: String) -> HTTPResponse {
        guard let state = store?.project?.editor else {
            return errorResponse("503 Service Unavailable", "no project open")
        }
        let query = parseQuery(path)
        let lang = query["lang"] ?? "ja"

        let cacheKey: String
        if let youtubeURL = store?.project?.media.youtubeURL,
           let videoID = YouTubeURLValidator.extractVideoID(youtubeURL) {
            cacheKey = "\(videoID).\(lang)"
        } else {
            return errorResponse("400 Bad Request", "no YouTube URL. diff requires YouTube subtitles as reference.")
        }

        guard let refRegions = youtubeSubtitleCache[cacheKey], !refRegions.isEmpty else {
            return errorResponse("400 Bad Request",
                "YouTube subtitles not loaded for lang=\(lang). Call GET /youtube-subtitles?lang=\(lang) first.")
        }

        let ourRegions = state.captionRegions
        var diffs: [ACPDiffEntry] = []
        var matchedCount = 0

        for refRegion in refRegions {
            let bestMatch = ourRegions.enumerated().max { a, b in
                overlapRatio(a.element, refRegion) < overlapRatio(b.element, refRegion)
            }
            guard let (idx, our) = bestMatch, overlapRatio(our, refRegion) > 0.1 else { continue }

            let sim = textSimilarity(our.text, refRegion.text)
            if sim > 0.7 {
                matchedCount += 1
            } else {
                diffs.append(ACPDiffEntry(
                    index: idx, startMs: our.startMs, endMs: our.endMs,
                    ours: our.text, reference: refRegion.text, similarity: sim
                ))
            }
        }

        diffs.sort { $0.similarity < $1.similarity }

        let result = ACPDiff(
            totalRegions: ourRegions.count,
            referenceCount: refRegions.count,
            matched: matchedCount,
            mismatched: diffs.count,
            diffs: diffs
        )
        return encodableResponse(result)
    }

    // MARK: - 類似度計算ヘルパー

    /// 2 リージョン間の時間オーバーラップ率 (IoU)
    private func overlapRatio(_ a: CaptionRegion, _ b: CaptionRegion) -> Double {
        let start = max(a.startMs, b.startMs)
        let end = min(a.endMs, b.endMs)
        let intersection = max(0, end - start)
        let union = (a.endMs - a.startMs) + (b.endMs - b.startMs) - intersection
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

}
