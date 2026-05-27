import Foundation

/// YouTube URL から動画 ID を抽出するユーティリティ。
enum YouTubeURLValidator {

    static func intent() -> String {
        """
        役割: YouTube の各種 URL 形式から 11 文字の動画 ID を抽出する純粋関数。
        外部依存なし、副作用なし。

        成熟度: stable
        対応形式: youtube.com/watch?v=, youtu.be/, youtube.com/embed/, youtube.com/shorts/
        """
    }

    /// YouTube URL 文字列から動画 ID を抽出する。無効な URL なら nil。
    static func extractVideoID(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased() else { return nil }

        // youtu.be/<id>
        if host == "youtu.be" {
            let id = url.pathComponents.dropFirst().first ?? ""
            return validID(id)
        }

        guard host.hasSuffix("youtube.com") else { return nil }

        let path = url.path

        // youtube.com/watch?v=<id>
        if path == "/watch" || path == "/watch/" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let vParam = components.queryItems?.first(where: { $0.name == "v" })?.value else {
                return nil
            }
            return validID(vParam)
        }

        // youtube.com/embed/<id>
        if path.hasPrefix("/embed/") {
            let id = String(path.dropFirst("/embed/".count)).components(separatedBy: "/").first ?? ""
            return validID(id)
        }

        // youtube.com/shorts/<id>
        if path.hasPrefix("/shorts/") {
            let id = String(path.dropFirst("/shorts/".count)).components(separatedBy: "/").first ?? ""
            return validID(id)
        }

        // youtube.com/v/<id>
        if path.hasPrefix("/v/") {
            let id = String(path.dropFirst("/v/".count)).components(separatedBy: "/").first ?? ""
            return validID(id)
        }

        return nil
    }

    /// URL の `&t=` / `#t=` パラメータから開始秒数を抽出する。
    /// `311s` → 311.0、`5m10s` → 310.0、数値のみ `311` → 311.0。
    static func extractStartTime(_ urlString: String) -> Double? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        guard let tValue = components.queryItems?.first(where: { $0.name == "t" })?.value,
              !tValue.isEmpty else { return nil }

        return parseTimeValue(tValue)
    }

    /// `311s`, `5m10s`, `1h2m3s`, `311` のような形式をパース。
    private static func parseTimeValue(_ value: String) -> Double? {
        // 数値のみ (例: "311")
        if let seconds = Double(value) { return seconds }

        // 末尾が "s" のみ (例: "311s")
        if value.hasSuffix("s") {
            let stripped = String(value.dropLast())
            if let seconds = Double(stripped) { return seconds }
        }

        // XhYmZs 形式
        var total: Double = 0
        var current = ""
        for ch in value {
            if ch == "h" {
                if let h = Double(current) { total += h * 3600 }
                current = ""
            } else if ch == "m" {
                if let m = Double(current) { total += m * 60 }
                current = ""
            } else if ch == "s" {
                if let s = Double(current) { total += s }
                current = ""
            } else {
                current.append(ch)
            }
        }
        return total > 0 ? total : nil
    }

    /// 動画 ID は通常 11 文字の英数字 + ハイフン + アンダースコア。
    private static func validID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 11,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return trimmed
    }
}
