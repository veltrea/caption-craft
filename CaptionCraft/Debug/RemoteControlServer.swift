import AudioCommon
import Foundation
import Network

// MARK: - RemoteControlServer

/// Claude (外部ツール) から CaptionCraft を HTTP で制御するための軽量サーバー。
/// curl でリクエストを送り、設定変更・書き起こし開始・状態確認などを行う。
///
/// 成熟度: experimental
///
/// エンドポイント:
///   GET  /status           — 現在の状態 (idle/transcribing/etc)、設定、リージョン数
///   POST /settings         — CaptionSettings を JSON で更新
///   POST /transcribe       — 全体書き起こし開始
///   POST /cancel           — 書き起こしキャンセル
///   GET  /regions          — 全リージョンを JSON で取得
///   GET  /regions?lang=fr  — 指定言語のリージョンだけ取得
///   GET  /region-audio?index=N — 指定リージョンの音声を WAV で書き出してパスを返す
///   POST /whisper          — 音声ファイルを指定言語で文字起こし {"path":"/tmp/x.wav","language":"fr"}
///
/// 使い方 (Claude 側):
///   curl http://localhost:9876/status
///   curl -X POST http://localhost:9876/settings -d '{"language":"ja","additionalLanguages":["fr"],"autoCorrectWithLLM":false}'
///   curl -X POST http://localhost:9876/transcribe
///   curl http://localhost:9876/regions
@MainActor
final class RemoteControlServer: ObservableObject {

    // MARK: - シングルトン

    /// アプリ全体で 1 つだけ起動し、ポート 9876 を占有する。
    /// 各 VideoEditorView は `register(store:transcriber:)` で参照を差し替える。
    static let shared = RemoteControlServer()

    private var listener: NWListener?
    private let port: UInt16

    /// 制御対象。VideoEditorView から注入される。
    weak var store: ProjectStore?
    weak var transcriber: CaptionTranscriber?

    /// ACP 拡張で追加された制御対象。
    weak var editorWindow: EditorWindowController?
    weak var translationService: TranslationService?
    weak var correctionService: CorrectionService?
    weak var dictionaryStore: DictionaryStore?
    weak var audioDownloader: YouTubeAudioDownloader?

    /// YouTube 字幕のキャッシュ。key = "\(videoID).\(lang)"
    var youtubeSubtitleCache: [String: [CaptionRegion]] = [:]

    init(port: UInt16 = 9876) {
        self.port = port
    }

    /// アクティブウィンドウから呼ばれ、制御対象を差し替える。
    /// 未起動なら自動で `start()` する。
    func register(
        store: ProjectStore,
        transcriber: CaptionTranscriber,
        translationService: TranslationService? = nil,
        correctionService: CorrectionService? = nil,
        dictionaryStore: DictionaryStore? = nil,
        audioDownloader: YouTubeAudioDownloader? = nil
    ) {
        self.store = store
        self.transcriber = transcriber
        if let t = translationService { self.translationService = t }
        if let c = correctionService { self.correctionService = c }
        if let d = dictionaryStore { self.dictionaryStore = d }
        if let a = audioDownloader { self.audioDownloader = a }
        if listener == nil {
            start()
        }
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            AppLog.app.error("RemoteControlServer 起動失敗: \(error.localizedDescription, privacy: .public)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Task { @MainActor in
                self?.handleConnection(conn)
            }
        }
        let p = port
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                AppLog.app.info("RemoteControlServer 起動: port \(p)")
            case .failed(let err):
                AppLog.app.error("RemoteControlServer 失敗: \(err.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data else {
                conn.cancel()
                return
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                let response = await self.routeRequest(raw)
                self.sendResponse(conn, response)
            }
        }
    }

    private func sendResponse(_ conn: NWConnection, _ response: HTTPResponse) {
        let header = """
        HTTP/1.1 \(response.status)\r
        Content-Type: application/json; charset=utf-8\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r

        """
        let body = response.body
        let full = Data((header + body).utf8)
        conn.send(content: full, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - Router

    private func routeRequest(_ raw: String) async -> HTTPResponse {
        let lines = raw.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            return HTTPResponse(status: "400 Bad Request", body: #"{"error":"empty request"}"#)
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return HTTPResponse(status: "400 Bad Request", body: #"{"error":"malformed request"}"#)
        }
        let method = String(parts[0])
        let path = String(parts[1])

        // POST のボディを抽出 (ヘッダーと空行の後)
        let bodyStr: String
        if let emptyLineIdx = raw.range(of: "\r\n\r\n") {
            bodyStr = String(raw[emptyLineIdx.upperBound...])
        } else {
            bodyStr = ""
        }

        switch (method, path) {
        // --- 既存 ---
        case ("GET", "/status"):
            return handleGetStatus()
        case ("POST", "/settings"):
            return handlePostSettings(bodyStr)
        case ("POST", "/transcribe"):
            return handlePostTranscribe()
        case ("POST", "/cancel"):
            return handlePostCancel()
        case ("POST", "/retranscribe-lang"):
            return handlePostRetranscribeLang(bodyStr)
        case ("GET", let p) where p.hasPrefix("/regions"):
            return handleGetRegions(path: p)
        case ("GET", let p) where p.hasPrefix("/region-audio"):
            return await handleGetRegionAudio(path: p)
        case ("POST", "/whisper"):
            return await handlePostWhisper(bodyStr)

        // --- ACP 拡張: プロジェクト操作 ---
        case ("POST", "/open"):
            return await handlePostOpen(bodyStr)
        case ("GET", "/project"):
            return handleGetProject()
        case ("POST", "/export-srt"):
            return handlePostExportSRT(bodyStr)
        case ("POST", "/save"):
            return handlePostSave(bodyStr)

        // --- ACP 拡張: 分析 ---
        case ("GET", let p) where p.hasPrefix("/screenshot"):
            return handleGetScreenshot()
        case ("GET", "/statistics"):
            return handleGetStatistics()
        case ("GET", let p) where p.hasPrefix("/problems"):
            return handleGetProblems(path: p)
        case ("GET", let p) where p.hasPrefix("/diff"):
            return handleGetDiff(path: p)

        // --- ACP 拡張: デバッグ ---
        case ("POST", "/try-transcribe"):
            return await handlePostTryTranscribe(bodyStr)
        case ("POST", "/ensemble"):
            return await handlePostEnsemble(bodyStr)
        case ("GET", let p) where p.hasPrefix("/narration-audio"):
            return await handleGetNarrationAudio(path: p)

        // --- ACP 拡張: パイプライン制御 ---
        case ("POST", "/translate"):
            return await handlePostTranslate(bodyStr)
        case ("POST", "/correct"):
            return await handlePostCorrect(bodyStr)
        case ("POST", "/edit-region"):
            return handlePostEditRegion(bodyStr)

        // --- E2E テスト支援 ---
        case ("GET", "/recent"):
            return handleGetRecent()
        case ("POST", "/close-nosave"):
            return handlePostCloseNoSave()
        case ("POST", "/save-regions"):
            return handlePostSaveRegions(bodyStr)
        case ("POST", "/save-logs"):
            return handlePostSaveLogs(bodyStr)

        // --- ACP 拡張: YouTube 字幕 ---
        case ("GET", let p) where p.hasPrefix("/youtube-subtitles"):
            return await handleGetYouTubeSubtitles(path: p)

        // --- ACP 拡張: システム監視 ---
        case ("GET", "/engines"):
            return handleGetEngines()
        case ("GET", "/health"):
            return handleGetHealth()
        case ("GET", let p) where p.hasPrefix("/logs"):
            return handleGetLogs(path: p)

        default:
            return handleHelp()
        }
    }

    // MARK: - Handlers

    private func handleGetStatus() -> HTTPResponse {
        guard let store, let transcriber else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"not connected"}"#)
        }
        let state = store.project?.editor
        let settings = state?.captionSettings ?? CaptionSettings()
        let regions = state?.captionRegions ?? []

        let statusStr: String
        switch transcriber.status {
        case .idle: statusStr = "idle"
        case .loadingModel(let p, let msg): statusStr = "loadingModel(\(Int(p * 100))%) \(msg)"
        case .transcribing(let p): statusStr = "transcribing(\(Int(p * 100))%)"
        case .correcting(let phase, let msg): statusStr = "correcting(\(phase.rawValue)) \(msg)"
        case .failed(let msg): statusStr = "failed: \(msg)"
        }

        let response = ACPStatus(
            status: statusStr,
            isRunning: transcriber.isRunning,
            regionCount: regions.count,
            sttEngine: PreferencesStore.shared.sttEngine.rawValue,
            settings: settings,
            translation: ACPTranslationInfo(
                targetLanguage: translationService?.targetLanguage ?? "",
                isTranslating: translationService?.isTranslating ?? false,
                translatedCount: regions.filter { $0.translatedText != nil }.count
            ),
            correction: ACPCorrectionInfo(
                isCorrecting: correctionService?.isRunning ?? false,
                correctedCount: regions.filter { !$0.corrections.isEmpty }.count
            )
        )
        return encodableResponse(response)
    }

    private func handlePostSettings(_ body: String) -> HTTPResponse {
        guard var state = store?.project?.editor else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"no project open"}"#)
        }
        guard let data = body.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HTTPResponse(status: "400 Bad Request", body: #"{"error":"invalid JSON"}"#)
        }

        // 設定を部分更新
        if let lang = dict["language"] as? String {
            state.captionSettings.language = lang
        }
        if let additional = dict["additionalLanguages"] as? [String] {
            state.captionSettings.additionalLanguages = additional
        }
        if let v = dict["autoCorrectWithDictionary"] as? Bool {
            state.captionSettings.autoCorrectWithDictionary = v
        }
        if let v = dict["autoCorrectWithLLM"] as? Bool {
            state.captionSettings.autoCorrectWithLLM = v
        }
        if let v = dict["silenceSplitMs"] as? Int {
            state.captionSettings.silenceSplitMs = v
        }
        if let v = dict["maxWordsPerSegment"] as? Int {
            state.captionSettings.maxWordsPerSegment = v
        }
        if let v = dict["splitLongRegions"] as? Bool {
            state.captionSettings.splitLongRegions = v
        }
        if let v = dict["vadMethod"] as? String, let method = VADMethod(rawValue: v) {
            state.captionSettings.vadMethod = method
        }

        store?.commitState(state)
        PreferencesStore.shared.saveWhisperSettings(state.captionSettings)

        // 翻訳先言語
        if let targetLang = dict["translationTargetLanguage"] as? String {
            translationService?.targetLanguage = targetLang
        }
        // LLM エンドポイント
        if let endpointStr = dict["llmEndpoint"] as? String,
           let url = URL(string: endpointStr) {
            translationService?.endpoint = url
        }
        // 翻訳モデル
        if let model = dict["translationModel"] as? String {
            translationService?.selectedModelID = model
        }

        // STT エンジン切り替え (例: "sttEngine": "qwen3")
        if let engineStr = dict["sttEngine"] as? String,
           let newType = STTEngineType(rawValue: engineStr) {
            PreferencesStore.shared.sttEngine = newType
            // CaptionTranscriber のエンジンインスタンスを差し替え
            if let transcriber {
                if transcriber.isRunning {
                    transcriber.cancel()
                }
                switch newType {
                case .whisper:    transcriber.engine = WhisperKitCaptionEngine()
                case .parakeet:   transcriber.engine = ParakeetCaptionEngine()
                case .qwen3:      transcriber.engine = Qwen3CaptionEngine()
                case .fasterWhisper: transcriber.engine = FasterWhisperCaptionEngine()
                }
                AppLog.app.info("RemoteControl: STT エンジンを \(newType.displayName, privacy: .public) に変更")
            }
        }

        return HTTPResponse(status: "200 OK", body: #"{"ok":true,"message":"settings updated"}"#)
    }

    private func handlePostTranscribe() -> HTTPResponse {
        guard let store, let transcriber else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"not connected"}"#)
        }
        guard !transcriber.isRunning else {
            return HTTPResponse(status: "409 Conflict", body: #"{"error":"already running"}"#)
        }
        transcriber.retranscribeAll(store: store)
        return HTTPResponse(status: "200 OK", body: #"{"ok":true,"message":"transcription started"}"#)
    }

    private func handlePostCancel() -> HTTPResponse {
        guard let transcriber else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"not connected"}"#)
        }
        transcriber.cancel()
        return HTTPResponse(status: "200 OK", body: #"{"ok":true,"message":"cancelled"}"#)
    }

    private func handlePostRetranscribeLang(_ body: String) -> HTTPResponse {
        guard let store, let transcriber else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"not connected"}"#)
        }
        guard let data = body.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HTTPResponse(status: "400 Bad Request", body: #"{"error":"invalid JSON. Expected: {\"index\":0,\"language\":\"fr\"} or {\"fromMs\":46000,\"toMs\":80000,\"language\":\"fr\"}"}"#)
        }
        guard let language = dict["language"] as? String else {
            return HTTPResponse(status: "400 Bad Request", body: #"{"error":"missing language (String)"}"#)
        }
        guard let state = store.project?.editor else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"no project open"}"#)
        }
        let regions = state.captionRegions

        // 範囲指定モード: fromMs/toMs で時間範囲内の全リージョンを一括 retranscribe
        if let fromMs = dict["fromMs"] as? Int, let toMs = dict["toMs"] as? Int {
            let targetIDs = regions
                .filter { $0.startMs >= fromMs && $0.endMs <= toMs }
                .map { $0.id }
            guard !targetIDs.isEmpty else {
                return HTTPResponse(status: "400 Bad Request", body: "{\"error\":\"no regions in range \(fromMs)-\(toMs)\"}")
            }
            transcriber.retranscribeRangeWithLanguage(regionIDs: targetIDs, language: language, store: store)
            let json: [String: Any] = [
                "ok": true,
                "message": "retranscribing \(targetIDs.count) regions (\(fromMs)-\(toMs)ms) with language=\(language)",
                "count": targetIDs.count
            ]
            return jsonResponse(json)
        }

        // 単一指定モード: index
        guard let index = dict["index"] as? Int else {
            return HTTPResponse(status: "400 Bad Request", body: #"{"error":"missing index (Int) or fromMs/toMs (Int)"}"#)
        }
        guard index >= 0 && index < regions.count else {
            return HTTPResponse(status: "400 Bad Request", body: "{\"error\":\"index out of range (0..\(regions.count - 1))\"}")
        }

        let regionID = regions[index].id
        transcriber.retranscribeWithLanguage(regionID: regionID, language: language, store: store)

        let json: [String: Any] = [
            "ok": true,
            "message": "retranscribing region \(index) with language=\(language)",
            "regionID": regionID.uuidString
        ]
        return jsonResponse(json)
    }

    private func handleGetRegions(path: String) -> HTTPResponse {
        guard let state = store?.project?.editor else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"no project open"}"#)
        }

        let query = parseQuery(path)
        var regions = state.captionRegions
        if let langFilter = query["lang"] {
            regions = regions.filter { $0.sourceLanguage == langFilter }
        }

        let response = ACPRegions(count: regions.count, regions: regions)
        return encodableResponse(response)
    }

    // MARK: - Region Audio Export

    private func handleGetRegionAudio(path: String) -> HTTPResponse {
        guard let store, let state = store.project?.editor else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"no project open"}"#)
        }

        // index パラメータ取得
        var index: Int?
        if let queryIdx = path.firstIndex(of: "?") {
            let query = String(path[path.index(after: queryIdx)...])
            for param in query.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                if kv.count == 2 && kv[0] == "index" {
                    index = Int(kv[1])
                }
            }
        }
        guard let idx = index, idx >= 0, idx < state.captionRegions.count else {
            return HTTPResponse(status: "400 Bad Request",
                                body: "{\"error\":\"invalid index. range: 0..\(state.captionRegions.count - 1)\"}")
        }

        let region = state.captionRegions[idx]

        // 音声ファイルパスを取得
        guard let videoPath = store.project?.media.screenVideoPath, !videoPath.isEmpty else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"no audio file"}"#)
        }
        let audioURL = URL(fileURLWithPath: videoPath)

        // WAV 書き出し
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("captioncraft-audio")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let wavName = String(format: "region_%03d_%d-%d.wav", idx, region.startMs, region.endMs)
        let wavURL = outDir.appendingPathComponent(wavName)

        do {
            let samples = try AudioFileLoader.load(url: audioURL, targetSampleRate: 16_000)
            let startSample = max(0, region.startMs * 16_000 / 1000)
            let endSample = min(samples.count, region.endMs * 16_000 / 1000)
            guard startSample < endSample else {
                return HTTPResponse(status: "400 Bad Request", body: #"{"error":"empty sample range"}"#)
            }
            let chunk = Array(samples[startSample..<endSample])
            try PipelineDiagnostics.writeWAV(samples: chunk, sampleRate: 16_000, to: wavURL)
        } catch {
            return HTTPResponse(status: "500 Internal Server Error",
                                body: "{\"error\":\"\(error.localizedDescription)\"}")
        }

        let json: [String: Any] = [
            "ok": true,
            "index": idx,
            "startMs": region.startMs,
            "endMs": region.endMs,
            "durationMs": region.endMs - region.startMs,
            "text": region.text,
            "path": wavURL.path
        ]
        return jsonResponse(json)
    }

    // MARK: - Whisper (単発文字起こし)

    private func handlePostWhisper(_ body: String) async -> HTTPResponse {
        guard let transcriber else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"not connected"}"#)
        }
        guard let data = body.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filePath = dict["path"] as? String else {
            return HTTPResponse(status: "400 Bad Request",
                                body: #"{"error":"invalid JSON. Expected: {\"path\":\"/tmp/x.wav\",\"language\":\"fr\"}"}"#)
        }
        let language = dict["language"] as? String ?? "auto"
        let fileURL = URL(fileURLWithPath: filePath)

        guard FileManager.default.fileExists(atPath: filePath) else {
            return HTTPResponse(status: "400 Bad Request", body: "{\"error\":\"file not found: \(filePath)\"}")
        }

        let engine = transcriber.engine
        do {
            try await engine.prepare { _ in }
            let samples = try AudioFileLoader.load(url: fileURL, targetSampleRate: 16_000)
            let text = try await engine.transcribeSamples(samples: samples, sampleRate: 16_000, language: language)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            let json: [String: Any] = [
                "ok": true,
                "text": trimmed,
                "language": language,
                "sampleCount": samples.count,
                "durationMs": samples.count * 1000 / 16_000
            ]
            return jsonResponse(json)
        } catch {
            return HTTPResponse(status: "500 Internal Server Error",
                                body: "{\"error\":\"\(error.localizedDescription)\"}")
        }
    }

    // MARK: - Helpers

    private func jsonResponse(_ dict: [String: Any]) -> HTTPResponse {
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return HTTPResponse(status: "200 OK", body: body)
    }

    func encodableResponse<T: Encodable>(_ value: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let body = String(data: data, encoding: .utf8) else {
            return HTTPResponse(status: "500 Internal Server Error", body: #"{"error":"encode failed"}"#)
        }
        return HTTPResponse(status: "200 OK", body: body)
    }

    func errorResponse(_ status: String = "400 Bad Request", _ message: String) -> HTTPResponse {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        return HTTPResponse(status: status, body: "{\"error\":\"\(escaped)\"}")
    }

    /// クエリパラメータをパースする
    func parseQuery(_ path: String) -> [String: String] {
        guard let queryIdx = path.firstIndex(of: "?") else { return [:] }
        let query = String(path[path.index(after: queryIdx)...])
        var result: [String: String] = [:]
        for param in query.split(separator: "&") {
            let kv = param.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                result[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return result
    }

    /// JSON ボディを辞書としてパースする
    func parseBody(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    // MARK: - E2E テスト支援

    /// 最近開いたファイルの履歴を返す。
    private func handleGetRecent() -> HTTPResponse {
        let docs = RecentDocumentsManager.shared.recentFiles
        let entries: [[String: Any]] = docs.map { doc in
            [
                "name": doc.name,
                "path": doc.path,
                "kind": doc.kind.rawValue,
                "lastOpenedAt": ISO8601DateFormatter().string(from: doc.lastOpenedAt),
                "exists": FileManager.default.fileExists(atPath: doc.path)
            ] as [String: Any]
        }
        let json: [String: Any] = [
            "count": entries.count,
            "recent": entries
        ]
        return jsonResponse(json)
    }

    /// プロジェクトを保存せずにウィンドウを閉じる。
    /// isDirty を false にしてから close() を呼ぶことで、保存ダイアログを回避する。
    private func handlePostCloseNoSave() -> HTTPResponse {
        guard let editorWindow else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"no editor window"}"#)
        }
        editorWindow.store.clearDirty()
        editorWindow.window?.close()
        return HTTPResponse(status: "200 OK", body: #"{"ok":true,"message":"closed without saving"}"#)
    }

    /// リージョンを JSON ファイルとしてプロジェクトフォルダ (または指定パス) に保存する。
    private func handlePostSaveRegions(_ body: String) -> HTTPResponse {
        guard let state = store?.project?.editor else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"no project open"}"#)
        }
        let regions = state.captionRegions

        let dict = parseBody(body)
        let outputPath: String
        if let specifiedPath = dict?["path"] as? String {
            outputPath = specifiedPath
        } else if let projectDir = resolveProjectDir() {
            outputPath = (projectDir as NSString).appendingPathComponent("regions.json")
        } else {
            return errorResponse("400 Bad Request", "path required (no project folder available)")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(regions)
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            return errorResponse("500 Internal Server Error", error.localizedDescription)
        }

        let json: [String: Any] = [
            "ok": true,
            "path": outputPath,
            "count": regions.count
        ]
        return jsonResponse(json)
    }

    /// 診断ログをプロジェクトフォルダ (または指定パス) に保存する。
    /// 内容: 設定、リージョン概要、VAD パラメータ、エンジン情報。
    private func handlePostSaveLogs(_ body: String) -> HTTPResponse {
        guard let store, let state = store.project?.editor else {
            return HTTPResponse(status: "503 Service Unavailable", body: #"{"error":"no project open"}"#)
        }

        let dict = parseBody(body)
        let outputPath: String
        if let specifiedPath = dict?["path"] as? String {
            outputPath = specifiedPath
        } else if let projectDir = resolveProjectDir() {
            let ts = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            outputPath = (projectDir as NSString).appendingPathComponent("diag_\(ts).json")
        } else {
            return errorResponse("400 Bad Request", "path required (no project folder available)")
        }

        let settings = state.captionSettings
        let regions = state.captionRegions

        let log: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "engine": PreferencesStore.shared.sttEngine.rawValue,
            "settings": [
                "language": settings.language,
                "additionalLanguages": settings.additionalLanguages,
                "vadMethod": settings.vadMethod.rawValue,
                "vadSensitivity": settings.vadSensitivity.rawValue,
                "silenceSplitMs": settings.silenceSplitMs,
                "minSegmentMs": settings.minSegmentMs,
                "maxWordsPerSegment": settings.maxWordsPerSegment,
                "splitLongRegions": settings.splitLongRegions,
                "autoCorrectWithDictionary": settings.autoCorrectWithDictionary,
                "autoCorrectWithLLM": settings.autoCorrectWithLLM,
            ] as [String: Any],
            "regionSummary": [
                "count": regions.count,
                "totalDurationMs": regions.reduce(0) { $0 + ($1.endMs - $1.startMs) },
                "emptyCount": regions.filter { $0.text.isEmpty }.count,
                "manuallyEditedCount": regions.filter { $0.isManuallyEdited }.count,
                "avgConfidence": regions.isEmpty ? 0 : regions.map(\.confidence).reduce(0, +) / Double(regions.count),
                "languages": Array(Set(regions.map(\.sourceLanguage))),
            ] as [String: Any]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            return errorResponse("500 Internal Server Error", error.localizedDescription)
        }

        let json: [String: Any] = [
            "ok": true,
            "path": outputPath
        ]
        return jsonResponse(json)
    }

    /// プロジェクトの保存先ディレクトリを解決する。
    /// .captioncraft パッケージがあればその親、なければ動画ファイルの親。
    private func resolveProjectDir() -> String? {
        if let savedURL = store?.savedURL {
            return savedURL.deletingLastPathComponent().path
        }
        if let videoPath = store?.project?.media.screenVideoPath, !videoPath.isEmpty {
            return (videoPath as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func handleHelp() -> HTTPResponse {
        let help: [String: Any] = [
            "endpoints": [
                "GET  /status", "GET  /project", "GET  /health", "GET  /engines",
                "GET  /regions", "GET  /regions?lang=fr",
                "GET  /statistics", "GET  /problems", "GET  /problems?threshold=0.6",
                "GET  /screenshot",
                "GET  /region-audio?index=N",
                "GET  /narration-audio?fromMs=N&toMs=M",
                "GET  /youtube-subtitles?lang=ja",
                "GET  /diff?reference=youtube&lang=ja",
                "GET  /logs?since=TIMESTAMP&category=transcribe&level=error",
                "POST /settings {language,additionalLanguages,sttEngine,translationTargetLanguage,...}",
                "POST /open {youtube:URL} or {file:PATH}",
                "POST /transcribe", "POST /cancel",
                "POST /translate", "POST /correct {mode:dictionary|llm}",
                "POST /try-transcribe {index,language,engine?}",
                "POST /ensemble {index,engine}",
                "POST /edit-region {index,text,sourceLanguage?}",
                "POST /retranscribe-lang {index,language}",
                "POST /export-srt {path,useTranslation?}",
                "POST /save {path?}",
                "POST /whisper {path,language}",
                "GET  /recent",
                "POST /close-nosave",
                "POST /save-regions {path?}",
                "POST /save-logs {path?}"
            ]
        ]
        return jsonResponse(help)
    }

    struct HTTPResponse {
        let status: String
        let body: String
    }
}

// MARK: - ACP Encodable レスポンス型

struct ACPStatus: Encodable {
    let status: String
    let isRunning: Bool
    let regionCount: Int
    let sttEngine: String
    let settings: CaptionSettings
    let translation: ACPTranslationInfo
    let correction: ACPCorrectionInfo
}

struct ACPTranslationInfo: Encodable {
    let targetLanguage: String
    let isTranslating: Bool
    let translatedCount: Int
}

struct ACPCorrectionInfo: Encodable {
    let isCorrecting: Bool
    let correctedCount: Int
}

struct ACPRegions: Encodable {
    let count: Int
    let regions: [CaptionRegion]
}

struct ACPProject: Encodable {
    let name: String
    let videoPath: String
    let youtubeURL: String?
    let durationMs: Int
    let regionCount: Int
    let isYouTubeMode: Bool
    let videoFileExists: Bool
}

struct ACPStatistics: Encodable {
    let totalRegions: Int
    let byLanguage: [String: Int]
    let avgConfidence: Double
    let emptyCount: Int
    let shortCount: Int
    let lowConfidenceCount: Int
    let translatedCount: Int
    let correctedCount: Int
    let totalDurationMs: Int
    let manuallyEditedCount: Int
}

struct ACPProblems: Encodable {
    let lowConfidence: [ACPProblemRegion]
    let empty: [ACPProblemRegion]
    let tooShort: [ACPProblemRegion]
}

struct ACPProblemRegion: Encodable {
    let index: Int
    let startMs: Int
    let endMs: Int
    let text: String
    let confidence: Double
    let sourceLanguage: String
    let reason: String
}

struct ACPDiff: Encodable {
    let totalRegions: Int
    let referenceCount: Int
    let matched: Int
    let mismatched: Int
    let diffs: [ACPDiffEntry]
}

struct ACPDiffEntry: Encodable {
    let index: Int
    let startMs: Int
    let endMs: Int
    let ours: String
    let reference: String
    let similarity: Double
}

struct ACPTryTranscribeResult: Encodable {
    let index: Int
    let startMs: Int
    let endMs: Int
    let current: String
    let result: String
    let language: String
    let engine: String
    let similarity: Double
    let durationMs: Int
}

struct ACPEngineInfo: Encodable {
    let id: String
    let name: String
    let summary: String
    let supportedLanguages: [String]
    let isCurrent: Bool
}

struct ACPHealth: Encodable {
    let ok: Bool
    let memoryUsedMB: Int
    let memoryTotalMB: Int
    let currentEngine: String
    let isTranscribing: Bool
    let isTranslating: Bool
    let isCorrecting: Bool
    let ytdlpInstalled: Bool
    let projectLoaded: Bool
    let regionCount: Int
}

struct ACPYouTubeSubtitles: Encodable {
    let ok: Bool
    let source: String
    let language: String
    let count: Int
    let regions: [CaptionRegion]
}
