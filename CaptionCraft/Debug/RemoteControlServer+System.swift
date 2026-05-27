import Foundation
import Darwin

// MARK: - ACP システム監視

extension RemoteControlServer {

    // MARK: GET /engines

    func handleGetEngines() -> HTTPResponse {
        let current = PreferencesStore.shared.sttEngine
        let engines = STTEngineType.allCases.map { type in
            let langs: [String] = type.supportedLanguageCodes.isEmpty
                ? ["all"]
                : type.supportedLanguageCodes.sorted()
            return ACPEngineInfo(
                id: type.rawValue,
                name: type.displayName,
                summary: type.summary,
                supportedLanguages: langs,
                isCurrent: type == current
            )
        }
        return encodableResponse(engines)
    }

    // MARK: GET /health

    func handleGetHealth() -> HTTPResponse {
        let (usedMB, totalMB) = memoryUsage()
        let health = ACPHealth(
            ok: true,
            memoryUsedMB: usedMB,
            memoryTotalMB: totalMB,
            currentEngine: PreferencesStore.shared.sttEngine.displayName,
            isTranscribing: transcriber?.isRunning ?? false,
            isTranslating: translationService?.isTranslating ?? false,
            isCorrecting: correctionService?.isRunning ?? false,
            ytdlpInstalled: FileManager.default.fileExists(atPath: ytdlpBinaryPath()),
            projectLoaded: store?.project != nil,
            regionCount: store?.project?.editor.captionRegions.count ?? 0
        )
        return encodableResponse(health)
    }

    // MARK: GET /logs

    func handleGetLogs(path: String) -> HTTPResponse {
        let query = parseQuery(path)
        let since = query["since"].flatMap { Double($0) }
        let category = query["category"]
        let level = query["level"]

        let entries = ACPLogStore.shared.entries(since: since, category: category, level: level)
        return encodableResponse(entries)
    }

    // MARK: - メモリ情報

    private func memoryUsage() -> (usedMB: Int, totalMB: Int) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let usedMB: Int
        if result == KERN_SUCCESS {
            usedMB = Int(info.resident_size / 1_048_576)
        } else {
            usedMB = 0
        }
        let totalMB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        return (usedMB, totalMB)
    }
}
