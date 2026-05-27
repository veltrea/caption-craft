import AudioCommon
import Foundation

// MARK: - ACP デバッグ

extension RemoteControlServer {

    // MARK: POST /try-transcribe

    func handlePostTryTranscribe(_ body: String) async -> HTTPResponse {
        guard let dict = parseBody(body) else {
            return errorResponse("400 Bad Request",
                "invalid JSON. Expected: {\"index\":N,\"language\":\"fr\"} or {\"fromMs\":N,\"toMs\":M,\"language\":\"fr\"}")
        }
        guard let store, let state = store.project?.editor else {
            return errorResponse("503 Service Unavailable", "no project open")
        }
        let language = dict["language"] as? String ?? "auto"
        let engineStr = dict["engine"] as? String
        let engineType: STTEngineType
        if let es = engineStr, let et = STTEngineType(rawValue: es) {
            engineType = et
        } else {
            engineType = PreferencesStore.shared.sttEngine
        }

        let regions = state.captionRegions

        // 音声ファイルパス
        guard let videoPath = store.project?.media.screenVideoPath, !videoPath.isEmpty else {
            return errorResponse("503 Service Unavailable", "no audio file")
        }
        let audioURL = URL(fileURLWithPath: videoPath)

        // 対象リージョンを特定
        var targets: [(index: Int, region: CaptionRegion)] = []

        if let fromMs = dict["fromMs"] as? Int, let toMs = dict["toMs"] as? Int {
            for (i, r) in regions.enumerated() {
                if r.startMs >= fromMs && r.endMs <= toMs {
                    targets.append((i, r))
                }
            }
            if targets.isEmpty {
                return errorResponse("400 Bad Request", "no regions in range \(fromMs)-\(toMs)")
            }
        } else if let index = dict["index"] as? Int {
            guard index >= 0 && index < regions.count else {
                return errorResponse("400 Bad Request", "index out of range (0..\(regions.count - 1))")
            }
            targets.append((index, regions[index]))
        } else {
            return errorResponse("400 Bad Request", "missing 'index' or 'fromMs'/'toMs'")
        }

        // エンジン準備
        let engine: CaptionEngine
        if engineType == PreferencesStore.shared.sttEngine, let currentEngine = transcriber?.engine {
            engine = currentEngine
        } else {
            engine = makeEngine(for: engineType)
        }

        do {
            try await engine.prepare { _ in }
            let samples = try AudioFileLoader.load(url: audioURL, targetSampleRate: 16_000)

            var results: [ACPTryTranscribeResult] = []
            for (idx, region) in targets {
                let startSample = max(0, region.startMs * 16_000 / 1000)
                let endSample = min(samples.count, region.endMs * 16_000 / 1000)
                guard startSample < endSample else { continue }
                let chunk = Array(samples[startSample..<endSample])

                let text = try await engine.transcribeSamples(
                    samples: chunk, sampleRate: 16_000, language: language
                )
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let sim = textSimilarity(region.text, trimmed)

                results.append(ACPTryTranscribeResult(
                    index: idx,
                    startMs: region.startMs,
                    endMs: region.endMs,
                    current: region.text,
                    result: trimmed,
                    language: language,
                    engine: engineType.rawValue,
                    similarity: sim,
                    durationMs: region.endMs - region.startMs
                ))
            }

            if results.count == 1 {
                return encodableResponse(results[0])
            }
            let wrapper: [String: Any] = ["count": results.count]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let resultsData = try? encoder.encode(results),
                  let resultsStr = String(data: resultsData, encoding: .utf8) else {
                return errorResponse("500 Internal Server Error", "encode failed")
            }
            let wrapperData = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted])
            var bodyStr = String(data: wrapperData ?? Data(), encoding: .utf8) ?? "{}"
            bodyStr = bodyStr.replacingOccurrences(of: "}", with: ",\"results\":\(resultsStr)}")
            return HTTPResponse(status: "200 OK", body: bodyStr)
        } catch {
            return errorResponse("500 Internal Server Error", "transcription failed: \(error.localizedDescription)")
        }
    }

    // MARK: POST /ensemble

    func handlePostEnsemble(_ body: String) async -> HTTPResponse {
        guard let dict = parseBody(body) else {
            return errorResponse("400 Bad Request", "invalid JSON. Expected: {\"index\":N,\"engine\":\"parakeet\"}")
        }
        guard let index = dict["index"] as? Int,
              let engineStr = dict["engine"] as? String,
              let secondaryType = STTEngineType(rawValue: engineStr) else {
            return errorResponse("400 Bad Request", "missing 'index' (Int) and 'engine' (String)")
        }
        guard let store, let state = store.project?.editor else {
            return errorResponse("503 Service Unavailable", "no project open")
        }
        let regions = state.captionRegions
        guard index >= 0 && index < regions.count else {
            return errorResponse("400 Bad Request", "index out of range")
        }
        guard let videoPath = store.project?.media.screenVideoPath, !videoPath.isEmpty else {
            return errorResponse("503 Service Unavailable", "no audio file")
        }

        let region = regions[index]
        let primaryType = PreferencesStore.shared.sttEngine

        let engine = makeEngine(for: secondaryType)
        do {
            try await engine.prepare { _ in }
            let samples = try AudioFileLoader.load(url: URL(fileURLWithPath: videoPath), targetSampleRate: 16_000)
            let startSample = max(0, region.startMs * 16_000 / 1000)
            let endSample = min(samples.count, region.endMs * 16_000 / 1000)
            guard startSample < endSample else {
                return errorResponse("400 Bad Request", "empty sample range")
            }
            let chunk = Array(samples[startSample..<endSample])
            let lang = region.sourceLanguage
            let secondaryText = try await engine.transcribeSamples(
                samples: chunk, sampleRate: 16_000, language: lang
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            let json: [String: Any] = [
                "ok": true,
                "index": index,
                "primaryEngine": primaryType.rawValue,
                "primaryText": region.text,
                "secondaryEngine": secondaryType.rawValue,
                "secondaryText": secondaryText,
                "matched": region.text == secondaryText
            ]
            let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(status: "200 OK", body: String(data: data ?? Data(), encoding: .utf8) ?? "{}")
        } catch {
            return errorResponse("500 Internal Server Error", "ensemble failed: \(error.localizedDescription)")
        }
    }

    // MARK: GET /narration-audio

    func handleGetNarrationAudio(path: String) async -> HTTPResponse {
        let query = parseQuery(path)
        guard let fromStr = query["fromMs"], let fromMs = Int(fromStr),
              let toStr = query["toMs"], let toMs = Int(toStr) else {
            return errorResponse("400 Bad Request", "missing fromMs and toMs. Example: /narration-audio?fromMs=44000&toMs=52000")
        }
        guard fromMs < toMs else {
            return errorResponse("400 Bad Request", "fromMs must be less than toMs")
        }
        guard let videoPath = store?.project?.media.screenVideoPath, !videoPath.isEmpty else {
            return errorResponse("503 Service Unavailable", "no audio file")
        }

        do {
            let samples = try AudioFileLoader.load(url: URL(fileURLWithPath: videoPath), targetSampleRate: 16_000)
            let startSample = max(0, fromMs * 16_000 / 1000)
            let endSample = min(samples.count, toMs * 16_000 / 1000)
            guard startSample < endSample else {
                return errorResponse("400 Bad Request", "empty sample range")
            }
            let chunk = Array(samples[startSample..<endSample])

            let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("captioncraft-audio")
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let wavURL = outDir.appendingPathComponent("narration_\(fromMs)-\(toMs).wav")
            try PipelineDiagnostics.writeWAV(samples: chunk, sampleRate: 16_000, to: wavURL)

            let json: [String: Any] = [
                "ok": true,
                "path": wavURL.path,
                "fromMs": fromMs,
                "toMs": toMs,
                "durationMs": toMs - fromMs
            ]
            let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(status: "200 OK", body: String(data: data ?? Data(), encoding: .utf8) ?? "{}")
        } catch {
            return errorResponse("500 Internal Server Error", "audio export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - ヘルパー

    func makeEngine(for type: STTEngineType) -> CaptionEngine {
        switch type {
        case .whisper:       return WhisperKitCaptionEngine()
        case .parakeet:      return ParakeetCaptionEngine()
        case .qwen3:         return Qwen3CaptionEngine()
        case .fasterWhisper: return FasterWhisperCaptionEngine()
        }
    }

    func textSimilarity(_ a: String, _ b: String) -> Double {
        let aBigrams = bigrams(a)
        let bBigrams = bigrams(b)
        guard !aBigrams.isEmpty || !bBigrams.isEmpty else { return a == b ? 1.0 : 0.0 }
        let intersection = aBigrams.intersection(bBigrams).count
        let union = aBigrams.union(bBigrams).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.lowercased().filter { !$0.isWhitespace })
        guard chars.count >= 2 else { return Set(chars.map { String($0) }) }
        var result = Set<String>()
        for i in 0..<(chars.count - 1) {
            result.insert(String(chars[i]) + String(chars[i + 1]))
        }
        return result
    }
}
