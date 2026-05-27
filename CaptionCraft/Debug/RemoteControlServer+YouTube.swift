import Foundation

// MARK: - ACP YouTube 字幕

extension RemoteControlServer {

    // MARK: GET /youtube-subtitles

    func handleGetYouTubeSubtitles(path: String) async -> HTTPResponse {
        guard let youtubeURL = store?.project?.media.youtubeURL,
              let videoID = YouTubeURLValidator.extractVideoID(youtubeURL) else {
            return errorResponse("400 Bad Request", "no YouTube URL in current project")
        }

        let query = parseQuery(path)
        let lang = query["lang"] ?? "ja"
        let cacheKey = "\(videoID).\(lang)"

        // キャッシュチェック
        if let cached = youtubeSubtitleCache[cacheKey] {
            let response = ACPYouTubeSubtitles(
                ok: true, source: "youtube-auto (cached)",
                language: lang, count: cached.count, regions: cached
            )
            return encodableResponse(response)
        }

        // yt-dlp バイナリのパス
        let binaryPath = ytdlpBinaryPath()
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            return errorResponse("503 Service Unavailable",
                "yt-dlp not installed. Open a YouTube video in the GUI first to trigger auto-install.")
        }

        // 出力ディレクトリ
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("captioncraft-ytsubtitles")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let outputTemplate = outDir.appendingPathComponent(videoID).path

        // yt-dlp で字幕をダウンロード
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "--write-auto-sub",
            "--sub-lang", lang,
            "--sub-format", "srt",
            "--skip-download",
            "--no-playlist",
            "--no-warnings",
            "-o", outputTemplate,
            "https://www.youtube.com/watch?v=\(videoID)"
        ]

        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return errorResponse("500 Internal Server Error", "yt-dlp failed to start: \(error.localizedDescription)")
        }

        let exitResult: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }

        guard exitResult == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            return errorResponse("500 Internal Server Error",
                "yt-dlp subtitle download failed (exit \(exitResult)): \(String(stderr.prefix(300)))")
        }

        // SRT ファイルを探す
        let srtPath = "\(outputTemplate).\(lang).srt"
        guard FileManager.default.fileExists(atPath: srtPath) else {
            // 自動字幕が利用できない場合
            // yt-dlp が出すファイル名パターンをチェック
            let altPatterns = [
                "\(outputTemplate).\(lang).vtt",
                "\(outputTemplate).\(lang).srv3"
            ]
            for alt in altPatterns {
                if FileManager.default.fileExists(atPath: alt) {
                    return errorResponse("500 Internal Server Error",
                        "subtitle downloaded but in unsupported format: \(URL(fileURLWithPath: alt).lastPathComponent). Only SRT is supported.")
                }
            }
            return errorResponse("404 Not Found",
                "no auto-generated subtitles available for lang=\(lang) on this video")
        }

        // SRTCodec でパース
        do {
            let regions = try SRTCodec.load(from: URL(fileURLWithPath: srtPath))
            youtubeSubtitleCache[cacheKey] = regions

            let response = ACPYouTubeSubtitles(
                ok: true, source: "youtube-auto",
                language: lang, count: regions.count, regions: regions
            )
            return encodableResponse(response)
        } catch {
            return errorResponse("500 Internal Server Error",
                "SRT parse failed: \(error.localizedDescription)")
        }
    }

    // MARK: - yt-dlp バイナリパス

    func ytdlpBinaryPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptionCraft")
        return dir.appendingPathComponent("yt-dlp_macos").path
    }
}
