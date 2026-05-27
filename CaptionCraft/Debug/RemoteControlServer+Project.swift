import Foundation

// MARK: - ACP プロジェクト操作

extension RemoteControlServer {

    // MARK: POST /open

    func handlePostOpen(_ body: String) async -> HTTPResponse {
        guard let dict = parseBody(body) else {
            return errorResponse("400 Bad Request", "invalid JSON. Expected: {\"youtube\":\"URL\"} or {\"file\":\"PATH\"}")
        }

        if let urlStr = dict["youtube"] as? String {
            return await openYouTube(urlStr)
        }
        if let path = dict["file"] as? String {
            return openFile(path)
        }
        return errorResponse("400 Bad Request", "missing 'youtube' or 'file' parameter")
    }

    private func openYouTube(_ urlStr: String) async -> HTTPResponse {
        guard let videoID = YouTubeURLValidator.extractVideoID(urlStr) else {
            return errorResponse("400 Bad Request", "invalid YouTube URL")
        }

        AppDelegate.shared?.openYouTubeURL(urlStr)

        let json: [String: Any] = [
            "ok": true,
            "mode": "youtube",
            "videoID": videoID,
            "message": "window created. Poll /status for load progress."
        ]
        return jsonResponse(json)
    }

    private func openFile(_ path: String) -> HTTPResponse {
        guard FileManager.default.fileExists(atPath: path) else {
            return errorResponse("400 Bad Request", "file not found: \(path)")
        }
        let url = URL(fileURLWithPath: path)
        AppDelegate.shared?.openFile(at: url)

        let json: [String: Any] = [
            "ok": true,
            "mode": "file",
            "path": path,
            "message": "file opened. Poll /status for load progress."
        ]
        return jsonResponse(json)
    }

    // MARK: GET /project

    func handleGetProject() -> HTTPResponse {
        guard let store, let project = store.project else {
            return errorResponse("503 Service Unavailable", "no project open")
        }
        let media = project.media
        let videoExists = !media.screenVideoPath.isEmpty &&
            FileManager.default.fileExists(atPath: media.screenVideoPath)

        let response = ACPProject(
            name: project.name,
            videoPath: media.screenVideoPath,
            youtubeURL: media.youtubeURL,
            durationMs: media.durationMs,
            regionCount: project.editor.captionRegions.count,
            isYouTubeMode: media.isYouTubeMode,
            videoFileExists: videoExists
        )
        return encodableResponse(response)
    }

    // MARK: POST /export-srt

    func handlePostExportSRT(_ body: String) -> HTTPResponse {
        guard let dict = parseBody(body),
              let path = dict["path"] as? String else {
            return errorResponse("400 Bad Request", "missing 'path' parameter. Expected: {\"path\":\"/tmp/output.srt\"}")
        }
        guard let regions = store?.project?.editor.captionRegions, !regions.isEmpty else {
            return errorResponse("400 Bad Request", "no regions to export")
        }

        let useTranslation = dict["useTranslation"] as? Bool ?? false
        let exportRegions: [CaptionRegion]
        if useTranslation {
            exportRegions = regions.map { r in
                var copy = r
                if let translated = r.translatedText, !translated.isEmpty {
                    copy.text = translated
                }
                return copy
            }
        } else {
            exportRegions = regions
        }

        let url = URL(fileURLWithPath: path)
        do {
            try SRTCodec.save(exportRegions, to: url)
            let json: [String: Any] = [
                "ok": true,
                "path": path,
                "regionCount": exportRegions.count,
                "useTranslation": useTranslation
            ]
            return jsonResponse(json)
        } catch {
            return errorResponse("500 Internal Server Error", "SRT export failed: \(error.localizedDescription)")
        }
    }

    // MARK: POST /save

    func handlePostSave(_ body: String) -> HTTPResponse {
        guard let store, store.project != nil else {
            return errorResponse("503 Service Unavailable", "no project open")
        }

        let dict = parseBody(body)
        let pathStr = dict?["path"] as? String

        do {
            if let pathStr {
                let url = URL(fileURLWithPath: pathStr)
                try store.save(to: url)
                return jsonResponse(["ok": true, "path": pathStr])
            } else if let savedURL = store.savedURL {
                try store.save(to: savedURL)
                return jsonResponse(["ok": true, "path": savedURL.path])
            } else {
                return errorResponse("400 Bad Request", "no save path. Provide {\"path\":\"...\"} or save the project via GUI first.")
            }
        } catch {
            return errorResponse("500 Internal Server Error", "save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - private helpers

    private func jsonResponse(_ dict: [String: Any]) -> HTTPResponse {
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return HTTPResponse(status: "200 OK", body: body)
    }
}
