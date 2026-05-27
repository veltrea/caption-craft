import Foundation

// MARK: - ACP パイプライン制御 (翻訳・校正・編集)

extension RemoteControlServer {

    // MARK: POST /translate

    func handlePostTranslate(_ body: String) async -> HTTPResponse {
        guard let store, let state = store.project?.editor else {
            return errorResponse("503 Service Unavailable", "no project open")
        }
        guard let translationService else {
            return errorResponse("503 Service Unavailable", "translation service not connected")
        }
        guard !translationService.isTranslating else {
            return errorResponse("409 Conflict", "translation already running")
        }
        let regions = state.captionRegions
        guard !regions.isEmpty else {
            return errorResponse("400 Bad Request", "no regions to translate")
        }

        do {
            let translated = try await translationService.translate(regions) { partialResult in
                var updatedState = state
                updatedState.captionRegions = partialResult
                store.commitState(updatedState)
            }
            var updatedState = state
            updatedState.captionRegions = translated
            store.commitState(updatedState)

            let count = translated.filter { $0.translatedText != nil }.count
            let json: [String: Any] = [
                "ok": true,
                "translatedCount": count,
                "totalRegions": translated.count,
                "targetLanguage": translationService.targetLanguage
            ]
            let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(status: "200 OK", body: String(data: data ?? Data(), encoding: .utf8) ?? "{}")
        } catch {
            return errorResponse("500 Internal Server Error", "translation failed: \(error.localizedDescription)")
        }
    }

    // MARK: POST /correct

    func handlePostCorrect(_ body: String) async -> HTTPResponse {
        guard let dict = parseBody(body) else {
            return errorResponse("400 Bad Request", "invalid JSON. Expected: {\"mode\":\"dictionary\"} or {\"mode\":\"llm\"}")
        }
        guard let mode = dict["mode"] as? String else {
            return errorResponse("400 Bad Request", "missing 'mode' (\"dictionary\" or \"llm\")")
        }
        guard let store, let state = store.project?.editor else {
            return errorResponse("503 Service Unavailable", "no project open")
        }
        let regions = state.captionRegions
        guard !regions.isEmpty else {
            return errorResponse("400 Bad Request", "no regions to correct")
        }

        switch mode {
        case "dictionary":
            return correctWithDictionary(regions: regions, state: state, store: store)
        case "llm":
            return await correctWithLLM(regions: regions, state: state, store: store)
        default:
            return errorResponse("400 Bad Request", "unknown mode '\(mode)'. Use 'dictionary' or 'llm'.")
        }
    }

    private func correctWithDictionary(
        regions: [CaptionRegion], state: EditorState, store: ProjectStore
    ) -> HTTPResponse {
        guard let dictionaryStore else {
            return errorResponse("503 Service Unavailable", "dictionary store not connected")
        }

        let (corrected, appliedIDs) = DictionaryCorrector.apply(
            dictionary: dictionaryStore.dictionary,
            to: regions
        )

        var updatedState = state
        updatedState.captionRegions = corrected
        store.commitState(updatedState)

        let json: [String: Any] = [
            "ok": true,
            "mode": "dictionary",
            "corrected": appliedIDs.count,
            "unchanged": regions.count - appliedIDs.count
        ]
        let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return HTTPResponse(status: "200 OK", body: String(data: data ?? Data(), encoding: .utf8) ?? "{}")
    }

    private func correctWithLLM(
        regions: [CaptionRegion], state: EditorState, store: ProjectStore
    ) async -> HTTPResponse {
        guard let correctionService else {
            return errorResponse("503 Service Unavailable", "correction service not connected")
        }
        guard !correctionService.isRunning else {
            return errorResponse("409 Conflict", "correction already running")
        }

        let endpoint = translationService?.endpoint ?? URL(string: "http://localhost:1234")!
        let client = LLMClient(endpoint: endpoint)
        let settings = state.captionSettings

        do {
            let corrected = try await correctionService.correct(
                regions: regions,
                domainHints: settings.domainHints,
                client: client
            ) { partialResult in
                var updatedState = state
                updatedState.captionRegions = partialResult
                store.commitState(updatedState)
            }

            var updatedState = state
            updatedState.captionRegions = corrected
            store.commitState(updatedState)

            let correctedCount = corrected.filter { !$0.corrections.isEmpty }.count
            let json: [String: Any] = [
                "ok": true,
                "mode": "llm",
                "corrected": correctedCount,
                "total": corrected.count
            ]
            let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(status: "200 OK", body: String(data: data ?? Data(), encoding: .utf8) ?? "{}")
        } catch {
            return errorResponse("500 Internal Server Error", "LLM correction failed: \(error.localizedDescription)")
        }
    }

    // MARK: POST /edit-region

    func handlePostEditRegion(_ body: String) -> HTTPResponse {
        guard let dict = parseBody(body) else {
            return errorResponse("400 Bad Request", "invalid JSON. Expected: {\"index\":N,\"text\":\"...\"}")
        }
        guard let index = dict["index"] as? Int else {
            return errorResponse("400 Bad Request", "missing 'index' (Int)")
        }
        guard let store, var state = store.project?.editor else {
            return errorResponse("503 Service Unavailable", "no project open")
        }
        let regions = state.captionRegions
        guard index >= 0 && index < regions.count else {
            return errorResponse("400 Bad Request", "index out of range (0..\(regions.count - 1))")
        }

        if let text = dict["text"] as? String {
            state.captionRegions[index].text = text
            state.captionRegions[index].isManuallyEdited = true
        }
        if let lang = dict["sourceLanguage"] as? String {
            state.captionRegions[index].sourceLanguage = lang
        }
        if let edited = dict["isManuallyEdited"] as? Bool {
            state.captionRegions[index].isManuallyEdited = edited
        }
        if let translated = dict["translatedText"] as? String {
            state.captionRegions[index].translatedText = translated
        }

        store.commitState(state)

        let updated = state.captionRegions[index]
        return encodableResponse(updated)
    }
}
