import Foundation

// MARK: - CaptionModelManager

/// Whisper モデルファイルの保管場所 (cache dir) を管理する。
/// large-v3 固定。cache パスの解決と「DL 済みかどうか」の薄い判定だけを担う。
///
/// 成熟度: experimental
@MainActor
final class CaptionModelManager: ObservableObject {

    let modelsDirectory: URL

    init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory ?? Self.defaultModelsDirectory()
        ensureDirectoryExists()
    }

    func isDownloaded() -> Bool {
        let dir = modelsDirectory.appendingPathComponent("large", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return items.contains { $0.hasSuffix(".mlmodelc") }
    }

    func removeModel() {
        let dir = modelsDirectory.appendingPathComponent("large", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private func ensureDirectoryExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: modelsDirectory.path) {
            try? fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        }
    }

    private static func defaultModelsDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("CaptionCraft", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
    }
}
