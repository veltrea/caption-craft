import Foundation

/// yt-dlp バイナリを使って YouTube の動画・音声をダウンロードする。
@MainActor
final class YouTubeAudioDownloader: NSObject, ObservableObject {

    static func intent() -> String {
        """
        役割: YouTube 動画を yt-dlp バイナリ経由でダウンロードし、
        動画は AVPlayer で表示、音声は CaptionTranscriber パイプラインに渡す。

        ScreenCaptureKit 方式の問題（実時間かかる、広告混入、タイムスタンプ不一致）を
        すべて解消する。ダウンロードファイルはアプリ内部でのみ使用し、
        ユーザーには直接アクセスさせない。

        成熟度: experimental
        依存: yt-dlp バイナリ (Application Support に自動配置)
        """
    }

    // MARK: - Published state

    @Published var isDownloading = false
    @Published var progress: String = ""
    @Published var downloadedVideoURL: URL?
    @Published var downloadedFileURL: URL?
    @Published var errorMessage: String?

    // MARK: - Constants

    private static let binaryName = "yt-dlp_macos"
    private static let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// ダウンロードファイルの保存先（アプリ専用ディレクトリ）
    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptionCraft/ytcache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptionCraft", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var binaryPath: URL {
        supportDir.appendingPathComponent(binaryName)
    }

    // MARK: - Binary management

    var isBinaryInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.binaryPath.path)
    }

    func installBinary() async {
        progress = "準備中…"

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: Self.downloadURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                errorMessage = "初回セットアップに失敗しました（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）"
                progress = ""
                return
            }

            let dest = Self.binaryPath
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: dest.path
            )

            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-d", "com.apple.quarantine", dest.path]
            try? xattr.run()
            xattr.waitUntilExit()

            progress = ""
        } catch {
            errorMessage = "初回セットアップに失敗: \(error.localizedDescription)"
            progress = ""
        }
    }

    // MARK: - Video download (動画+音声)

    /// YouTube URL から動画（映像+音声）をダウンロードする。
    /// AVPlayer で再生可能な mp4 ファイルを返す。
    func downloadVideo(from urlString: String) async -> URL? {
        guard let videoID = YouTubeURLValidator.extractVideoID(urlString) else {
            errorMessage = "有効な YouTube URL ではありません"
            return nil
        }

        if !isBinaryInstalled {
            await installBinary()
            guard isBinaryInstalled else { return nil }
        }

        // キャッシュに既にあればそのまま返す
        let outputPath = Self.cacheDir.appendingPathComponent("\(videoID).mp4")
        if FileManager.default.fileExists(atPath: outputPath.path) {
            downloadedVideoURL = outputPath
            downloadedFileURL = outputPath
            return outputPath
        }

        errorMessage = nil
        isDownloading = true
        progress = "読み込み中…"

        let process = Process()
        process.executableURL = Self.binaryPath
        process.arguments = [
            "-f", "best[ext=mp4][height<=720]/best[ext=mp4][height<=1080]/best[ext=mp4]/best",
            "-o", outputPath.path,
            "--no-playlist",
            "--newline",
            "https://www.youtube.com/watch?v=\(videoID)"
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stderrData = Data()

        // 進捗を逐次読み取り（--newline で行単位出力される）
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            // yt-dlp の進捗行: "[download]  45.2% of ~500MiB ..."
            if let pct = Self.parseProgress(line) {
                DispatchQueue.main.async {
                    self?.progress = "読み込み中… \(pct)%"
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrData.append(data) }
        }

        do {
            try process.run()
        } catch {
            errorMessage = "読み込みに失敗しました"
            isDownloading = false
            progress = ""
            return nil
        }

        let result: URL? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: outputPath.path) {
                    continuation.resume(returning: outputPath)
                } else {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    DispatchQueue.main.async {
                        self.errorMessage = "読み込みに失敗しました: \(stderr.prefix(200))"
                    }
                    continuation.resume(returning: nil)
                }
            }
        }

        isDownloading = false
        progress = ""

        if let url = result {
            downloadedVideoURL = url
            downloadedFileURL = url
        }
        return result
    }

    /// yt-dlp の出力行からパーセンテージを抽出する
    nonisolated private static func parseProgress(_ line: String) -> String? {
        // "[download]  45.2% of ~500MiB at 12.3MiB/s"
        // "[download] 100% of 500MiB"
        guard line.contains("[download]") else { return nil }
        let pattern = #"(\d+\.?\d*)%"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        let match = line[range].dropLast() // "%" を除去
        return String(match)
    }

    // MARK: - Audio-only download (STT 用、動画が既にある場合は不要)

    func downloadAudio(from urlString: String) async -> URL? {
        guard let videoID = YouTubeURLValidator.extractVideoID(urlString) else {
            errorMessage = "有効な YouTube URL ではありません"
            return nil
        }

        if !isBinaryInstalled {
            await installBinary()
            guard isBinaryInstalled else { return nil }
        }

        let outputPath = Self.cacheDir.appendingPathComponent("\(videoID).m4a")
        if FileManager.default.fileExists(atPath: outputPath.path) {
            downloadedFileURL = outputPath
            return outputPath
        }

        errorMessage = nil
        isDownloading = true
        progress = "読み込み中…"

        let process = Process()
        process.executableURL = Self.binaryPath
        process.arguments = [
            "-f", "bestaudio[ext=m4a]/bestaudio",
            "-o", outputPath.path,
            "--no-playlist",
            "--no-warnings",
            "https://www.youtube.com/watch?v=\(videoID)"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            errorMessage = "読み込みに失敗しました"
            isDownloading = false
            progress = ""
            return nil
        }

        let result: URL? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()

                if process.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: outputPath.path) {
                    continuation.resume(returning: outputPath)
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: data, encoding: .utf8) ?? ""
                    DispatchQueue.main.async {
                        self.errorMessage = "読み込みに失敗しました: \(stderr.prefix(200))"
                    }
                    continuation.resume(returning: nil)
                }
            }
        }

        isDownloading = false
        progress = ""

        if let url = result {
            downloadedFileURL = url
        }
        return result
    }

    /// キャッシュをクリアする
    func cleanup() {
        if let url = downloadedVideoURL {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = downloadedFileURL, url != downloadedVideoURL {
            try? FileManager.default.removeItem(at: url)
        }
        downloadedVideoURL = nil
        downloadedFileURL = nil
        progress = ""
        errorMessage = nil
    }

    func reset() {
        cleanup()
    }
}
