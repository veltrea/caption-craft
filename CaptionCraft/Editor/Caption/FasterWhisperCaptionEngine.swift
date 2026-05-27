import AVFoundation
import Foundation

// MARK: - FasterWhisperCaptionEngine

/// CaptionEngine の faster-whisper (CTranslate2) 実装。
///
/// 設計メモ:
/// - Python 常駐サーバー (scripts/stt/faster_whisper_server.py) と HTTP 通信。
/// - Whisper Large v3 を CTranslate2 int8 量子化で高速推論。
/// - **多言語対応の核心**: 各チャンクで言語自動検出し、検出言語でそのまま書き起こす。
///   翻訳しない。言語学習者向けの「原語そのまま字幕」を実現する。
/// - 短い音声で言語検出が不安定な場合は settings.language をフォールバックとして使用。
///
/// アーキテクチャ:
/// - prepare() で Python サーバーをバックグラウンド起動 + モデルロード待ち。
/// - transcribeSamples() は一時 WAV → HTTP POST → JSON レスポンス。
/// - アプリ終了時に /shutdown を叩いてサーバー停止。
///
/// 成熟度: experimental
final class FasterWhisperCaptionEngine: CaptionEngine {

    /// サーバーのポート。
    private let port: UInt16 = 9877
    private let modelSize = "large-v3"

    /// サーバープロセス参照。
    private var serverProcess: Process?

    /// scripts/stt/ ディレクトリのパス。
    private var scriptsDir: String {
        let srcRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Caption/
            .deletingLastPathComponent()   // Editor/
            .deletingLastPathComponent()   // CaptionCraft/
            .deletingLastPathComponent()   // project root
        let devPath = srcRoot.appendingPathComponent("scripts/stt").path
        if FileManager.default.fileExists(atPath: devPath + "/faster_whisper_server.py") {
            return devPath
        }
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = resourcePath + "/scripts/stt"
            if FileManager.default.fileExists(atPath: bundled + "/faster_whisper_server.py") {
                return bundled
            }
        }
        return devPath
    }

    /// Python venv が存在するか。
    func isAvailable() async -> Bool {
        let python = scriptsDir + "/venv/bin/python3"
        return FileManager.default.fileExists(atPath: python)
    }

    /// サーバー起動 + モデルロード完了を待つ。
    func prepare(
        progress: @MainActor @escaping (Double) -> Void
    ) async throws {
        // 既にサーバーが動いているか確認
        if await isServerReady() {
            AppLog.caption.info("FasterWhisper: サーバー既に起動中")
            await progress(1.0)
            return
        }

        let python = scriptsDir + "/venv/bin/python3"
        let script = scriptsDir + "/faster_whisper_server.py"

        guard FileManager.default.fileExists(atPath: python) else {
            throw CaptionEngineError.engineUnavailable(
                "faster-whisper の Python 環境が未セットアップです。\n" +
                "ターミナルで: pip install faster-whisper"
            )
        }

        AppLog.caption.info("FasterWhisper: サーバー起動中 (port \(self.port)) python=\(python, privacy: .public) script=\(script, privacy: .public)")
        await progress(0.1)

        guard FileManager.default.fileExists(atPath: script) else {
            throw CaptionEngineError.engineUnavailable("サーバースクリプトが見つかりません: \(script)")
        }

        // ログファイルを事前作成（FileHandle(forWritingAtPath:) は既存ファイルのみ開ける）
        let logPath = "/tmp/faster_whisper_server.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)

        // サーバーをバックグラウンドで起動
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script, "--port", "\(port)", "--model", modelSize]
        process.environment = ProcessInfo.processInfo.environment

        // stderr を Pipe で捕獲（起動失敗の診断用）
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
            self.serverProcess = process
            AppLog.caption.info("FasterWhisper: プロセス起動成功 (PID \(process.processIdentifier))")
        } catch {
            // Pipe から stderr を読んで診断情報を出す
            let errData = stderrPipe.fileHandleForReading.availableData
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            AppLog.caption.error("FasterWhisper: プロセス起動失敗: \(error.localizedDescription, privacy: .public) stderr: \(errStr.prefix(500), privacy: .public)")
            throw CaptionEngineError.engineUnavailable("サーバー起動失敗: \(error.localizedDescription)")
        }

        // stderr をバックグラウンドでログファイルに書き出す
        Task.detached {
            let handle = stderrPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let str = String(data: data, encoding: .utf8) {
                    AppLog.caption.info("FasterWhisper stderr: \(str.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
                }
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            }
        }

        await progress(0.3)

        // ヘルスチェックでモデルロード完了を待つ (最大120秒)
        let deadline = Date().addingTimeInterval(120)
        var ready = false
        while Date() < deadline {
            try Task.checkCancellation()
            if await isServerReady() {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2秒待ち
        }

        guard ready else {
            serverProcess?.terminate()
            serverProcess = nil
            throw CaptionEngineError.engineUnavailable("サーバーのモデルロードがタイムアウト (120秒)")
        }

        await progress(1.0)
        AppLog.caption.info("FasterWhisper: 準備完了")
    }

    // MARK: - File transcription

    func transcribe(
        url: URL,
        language: String,
        progress: @MainActor @escaping (Double) -> Void,
        onSegments: (@MainActor ([RawTranscriptionSegment]) -> Void)? = nil
    ) async throws -> [RawTranscriptionSegment] {
        if !(await isServerReady()) {
            try await prepare { _ in }
        }

        AppLog.transcribe.info("FasterWhisper transcribe: \(url.lastPathComponent, privacy: .public)")
        await progress(0.0)

        let defaultLang = (language == "auto" || language.isEmpty) ? nil : language
        let body: [String: Any] = [
            "audio_path": url.path,
            "default_lang": defaultLang as Any,
            "threshold": 0.6
        ]

        let response = try await postJSON(path: "/transcribe-file", body: body, timeout: 600)

        guard let segmentsArray = response["segments"] as? [[String: Any]] else {
            throw CaptionEngineError.transcriptionFailed("レスポンスに segments がありません")
        }

        let segments: [RawTranscriptionSegment] = segmentsArray.compactMap { dict in
            guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
            let startMs = dict["start_ms"] as? Int ?? 0
            let endMs = dict["end_ms"] as? Int ?? 0
            let confidence = dict["confidence"] as? Double ?? 0.8
            return RawTranscriptionSegment(
                text: text,
                startMs: startMs,
                endMs: endMs,
                confidence: confidence
            )
        }

        await progress(1.0)
        await onSegments?(segments)
        AppLog.transcribe.info("FasterWhisper transcribe 完了: \(segments.count) segments")
        return segments
    }

    // MARK: - Chunk transcription (VAD 経由)

    func transcribeSamples(
        samples: [Float],
        sampleRate: Int,
        language: String
    ) async throws -> String {
        if !(await isServerReady()) {
            try await prepare { _ in }
        }

        // 一時 WAV に書き出し
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw_chunk_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try writePCMToWAV(samples: samples, sampleRate: sampleRate, url: tmpURL)

        let defaultLang = (language == "auto" || language.isEmpty) ? nil : language
        let body: [String: Any] = [
            "audio_path": tmpURL.path,
            "default_lang": defaultLang as Any,
            "threshold": 0.6
        ]

        let response = try await postJSON(path: "/transcribe", body: body, timeout: 60)
        return response["text"] as? String ?? ""
    }

    // MARK: - Language detection

    /// faster-whisper の言語検出を利用。
    func detectLanguage(
        samples: [Float],
        sampleRate: Int
    ) async throws -> (language: String, langProbs: [String: Float])? {
        if !(await isServerReady()) {
            try await prepare { _ in }
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw_detect_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try writePCMToWAV(samples: samples, sampleRate: sampleRate, url: tmpURL)

        let body: [String: Any] = [
            "audio_path": tmpURL.path,
            "default_lang": NSNull(),
            "threshold": 0.0  // 閾値0で常に自動検出結果を返す
        ]

        let response = try await postJSON(path: "/transcribe", body: body, timeout: 30)
        guard let lang = response["lang"] as? String,
              let prob = response["lang_prob"] as? Double else {
            return nil
        }
        return (language: lang, langProbs: [lang: Float(prob)])
    }

    // MARK: - Lifecycle

    deinit {
        // サーバーシャットダウン
        let url = URL(string: "http://127.0.0.1:\(port)/shutdown")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Fire-and-forget
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - HTTP helpers

    private func isServerReady() async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["status"] as? String == "ready"
        } catch {
            return false
        }
    }

    private func postJSON(path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw CaptionEngineError.transcriptionFailed("HTTP レスポンスなし")
        }
        guard http.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw CaptionEngineError.transcriptionFailed("HTTP \(http.statusCode): \(errBody.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptionEngineError.transcriptionFailed("JSON パース失敗")
        }
        return json
    }

    // MARK: - WAV 書き出し

    private func writePCMToWAV(samples: [Float], sampleRate: Int, url: URL) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2)
        let fileSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        try data.write(to: url)
    }
}
