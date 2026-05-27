import Foundation

// MARK: - SRTCodec

/// SRT (SubRip) 形式の読み書き。CaptionRegion との相互変換を提供する。
///
/// 成熟度: experimental
///
/// SRT フォーマット仕様:
/// ```
/// 1
/// 00:00:01,000 --> 00:00:03,500
/// テキスト行 1
/// テキスト行 2 (複数行可)
///
/// 2
/// 00:00:04,000 --> 00:00:06,000
/// 次の字幕
/// ```
///
/// このクラスは副作用なし・SDK 非依存。純粋な文字列処理のみ行う。
enum SRTCodec {

    static func intent() -> String {
        """
        役割: SRT 形式のパース (文字列 → CaptionRegion 配列) と
              シリアライズ (CaptionRegion 配列 → SRT 文字列) を行う。
        成熟度: experimental
        依存: CaptionRegion (Models/CaptionRegion.swift)
        変更時の注意: SRT タイムコードは `HH:MM:SS,mmm` (カンマ区切り)。
                     VTT の `HH:MM:SS.mmm` (ドット区切り) とは異なる。
        """
    }

    // MARK: - Parse

    /// SRT 文字列をパースして CaptionRegion 配列を返す。
    /// 不正なエントリはスキップする (エラーではなく警告レベル)。
    static func parse(_ srt: String) -> [CaptionRegion] {
        let blocks = srt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var regions: [CaptionRegion] = []

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            // 最低 2 行必要: 番号行 + タイムコード行 (テキストが空の場合もある)
            guard lines.count >= 2 else { continue }

            // タイムコード行を探す (`-->` を含む行)
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            guard let (startMs, endMs) = parseTimeLine(lines[timeLineIndex]) else {
                continue
            }

            // タイムコード行の後がテキスト
            let textLines = lines.dropFirst(timeLineIndex + 1)
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            regions.append(CaptionRegion(
                startMs: startMs,
                endMs: endMs,
                text: text,
                isManuallyEdited: true,
                sourceLanguage: "auto",
                confidence: 1.0
            ))
        }

        return regions
    }

    /// SRT ファイルを読み込んでパースする。
    static func load(from url: URL) throws -> [CaptionRegion] {
        AppLog.srt.info("SRT 読み込み: \(url.lastPathComponent, privacy: .public)")
        // BOM 付き UTF-8 や Shift-JIS 等に対応するため、まず UTF-8 で試し、
        // 失敗したら .isoLatin1 にフォールバック
        let text: String
        var encoding: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
            encoding = "utf-8"
        } else if let latin = try? String(contentsOf: url, encoding: .isoLatin1) {
            text = latin
            encoding = "iso-latin-1"
        } else {
            AppLog.srt.error("エンコーディング不明: \(url.path, privacy: .public)")
            throw SRTCodecError.encodingUnsupported
        }
        let regions = parse(text)
        AppLog.srt.info("SRT パース完了: \(regions.count) entries (encoding=\(encoding, privacy: .public))")
        return regions
    }

    // MARK: - Write

    /// CaptionRegion 配列を SRT 文字列にシリアライズする。
    /// regions は startMs 昇順でソートして出力する。
    static func write(_ regions: [CaptionRegion]) -> String {
        let sorted = regions.sorted { $0.startMs < $1.startMs }
        var lines: [String] = []

        for (index, region) in sorted.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(formatTime(region.startMs)) --> \(formatTime(region.endMs))")
            lines.append(region.text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// CaptionRegion 配列を SRT ファイルとして保存する。
    static func save(_ regions: [CaptionRegion], to url: URL) throws {
        AppLog.srt.info("SRT 書き出し: \(regions.count) entries → \(url.lastPathComponent, privacy: .public)")
        let content = write(regions)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let bytes = content.utf8.count
        AppLog.srt.info("SRT 書き出し完了: \(bytes) bytes")
    }

    // MARK: - Time formatting

    /// ミリ秒 → SRT タイムコード `HH:MM:SS,mmm`
    static func formatTime(_ ms: Int) -> String {
        let totalMs = max(0, ms)
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1_000
        let millis = totalMs % 1_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, millis)
    }

    /// SRT タイムコード `HH:MM:SS,mmm` → ミリ秒。ドット区切り (VTT 形式) も受け入れる。
    static func parseTime(_ str: String) -> Int? {
        // "00:01:23,456" or "00:01:23.456"
        let cleaned = str.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")

        let parts = cleaned.split(separator: ":")
        guard parts.count == 3 else { return nil }

        guard let h = Int(parts[0]) else { return nil }
        guard let m = Int(parts[1]) else { return nil }

        // 秒.ミリ秒
        let secParts = parts[2].split(separator: ".")
        guard secParts.count >= 1, let s = Int(secParts[0]) else { return nil }
        let millis: Int
        if secParts.count >= 2 {
            let msStr = secParts[1]
            // "456" → 456, "45" → 450, "4" → 400
            let padded = msStr.padding(toLength: 3, withPad: "0", startingAt: 0)
            millis = Int(padded.prefix(3)) ?? 0
        } else {
            millis = 0
        }

        return h * 3_600_000 + m * 60_000 + s * 1_000 + millis
    }

    // MARK: - Private

    /// `00:00:01,000 --> 00:00:03,500` 形式の行をパースする。
    private static func parseTimeLine(_ line: String) -> (Int, Int)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        guard let start = parseTime(parts[0]),
              let end = parseTime(parts[1]) else { return nil }
        return (start, end)
    }
}

// MARK: - SRTCodecError

enum SRTCodecError: LocalizedError {
    case encodingUnsupported

    var errorDescription: String? {
        switch self {
        case .encodingUnsupported:
            return "SRT ファイルの文字エンコーディングを認識できませんでした"
        }
    }
}
