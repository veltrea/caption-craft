import Foundation

// MARK: - ACPLogStore

/// ACP (Agent Control Protocol) 用のリングバッファ式ログストア。
/// パイプラインの重要イベントを蓄積し、GET /logs で Claude に返す。
///
/// 成熟度: experimental
final class ACPLogStore {

    static let shared = ACPLogStore()

    struct LogEntry: Encodable {
        let timestamp: Double
        let category: String
        let level: String
        let message: String
    }

    private var buffer: [LogEntry] = []
    private let maxEntries = 500
    private let lock = NSLock()

    func append(category: String, level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        let entry = LogEntry(
            timestamp: Date().timeIntervalSince1970,
            category: category,
            level: level,
            message: message
        )
        buffer.append(entry)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
    }

    func entries(
        since: Double? = nil,
        category: String? = nil,
        level: String? = nil
    ) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        var result = buffer
        if let since { result = result.filter { $0.timestamp > since } }
        if let category { result = result.filter { $0.category == category } }
        if let level { result = result.filter { $0.level == level } }
        return result
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }
}
