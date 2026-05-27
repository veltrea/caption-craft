import Foundation

// MARK: - DictionaryStore

/// 校正辞書の永続化ストア。
/// アプリ全体で共有 (プロジェクト単位ではない)。
/// ~/Library/Application Support/CaptionCraft/correction_dictionary.json に保存。
///
/// 成熟度: experimental
@MainActor
final class DictionaryStore: ObservableObject {

    static func intent() -> String {
        """
        役割: CorrectionDictionary の JSON 永続化と CRUD 操作。
              アプリ起動時に自動ロード、変更時に自動セーブ。
        成熟度: experimental
        依存: CorrectionDictionary, DictionaryEntry
        変更時の注意: ファイルパスを変えると既存辞書が行方不明になる。
        """
    }

    @Published private(set) var dictionary: CorrectionDictionary = CorrectionDictionary()

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("CaptionCraft", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("correction_dictionary.json")

        load()
    }

    /// テスト用: 任意の URL を指定。
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - CRUD

    func addEntry(_ entry: DictionaryEntry) {
        dictionary.entries.append(entry)
        save()
    }

    func updateEntry(_ entry: DictionaryEntry) {
        guard let idx = dictionary.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        dictionary.entries[idx] = entry
        save()
    }

    func removeEntry(id: UUID) {
        dictionary.entries.removeAll { $0.id == id }
        save()
    }

    func incrementUseCount(id: UUID) {
        guard let idx = dictionary.entries.firstIndex(where: { $0.id == id }) else { return }
        dictionary.entries[idx].useCount += 1
        save()
    }

    /// wrong が既に登録済みか (重複チェック)。
    func hasEntry(wrong: String) -> Bool {
        dictionary.entries.contains { $0.wrong.lowercased() == wrong.lowercased() }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            AppLog.caption.info("校正辞書なし: 新規作成")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            dictionary = try JSONDecoder().decode(CorrectionDictionary.self, from: data)
            AppLog.caption.info("校正辞書ロード: \(self.dictionary.entries.count) entries")
        } catch {
            AppLog.caption.error("校正辞書の読み込みに失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(dictionary)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.caption.error("校正辞書の保存に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }
}
