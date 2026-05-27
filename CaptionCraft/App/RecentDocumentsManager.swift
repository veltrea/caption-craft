import Foundation

/// 最近開いた書類の履歴を UserDefaults で管理する。
/// macOS 標準の NSDocumentController を使わず、自前で実装する
/// (CaptionCraft は NSDocument ベースではないため)。
///
/// 成熟度: experimental
@MainActor
final class RecentDocumentsManager: ObservableObject {

    static func intent() -> String {
        return """
        役割: 最近開いたファイル (動画 / .captioncraft プロジェクト) の履歴を管理する。
        UserDefaults にパスリストを保存し、File メニューの「最近使った書類」サブメニューと
        RemoteControlServer の GET /recent エンドポイントの両方から利用される。

        成熟度: experimental

        変更時の注意:
        - UserDefaults キーを変えると既存の履歴が消える。
        - maxCount を減らすと古い履歴が切り捨てられる（復元不可）。
        """
    }

    static let shared = RecentDocumentsManager()

    @Published private(set) var recentFiles: [RecentDocument] = []

    private static let defaultsKey = "CaptionCraft.recentDocuments.v1"
    private let maxCount = 20

    private init() {
        load()
    }

    // MARK: - Public API

    /// ファイルを開いたときに呼ぶ。リストの先頭に追加し、重複は除去する。
    func noteOpened(url: URL, kind: RecentDocument.Kind) {
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let entry = RecentDocument(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            kind: kind,
            lastOpenedAt: Date(),
            bookmark: bookmark
        )
        var list = recentFiles.filter { $0.path != entry.path }
        list.insert(entry, at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        recentFiles = list
        save()
    }

    /// 履歴をクリアする。
    func clearAll() {
        recentFiles = []
        save()
    }

    /// 存在しないファイルを履歴から除去する。
    func pruneInvalid() {
        recentFiles = recentFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        save()
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(recentFiles) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 配列全体を一括デコード。Kind 変更で古いエントリが壊れた場合は
        // JSON 配列を個別にデコードしてスキップする。
        if let decoded = try? decoder.decode([RecentDocument].self, from: data) {
            recentFiles = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
        } else if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            recentFiles = jsonArray.compactMap { item in
                guard let itemData = try? JSONSerialization.data(withJSONObject: item),
                      let doc = try? decoder.decode(RecentDocument.self, from: itemData),
                      FileManager.default.fileExists(atPath: doc.path) else { return nil }
                return doc
            }
            save()
        }
    }
}

// MARK: - RecentDocument

struct RecentDocument: Codable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let kind: Kind
    let lastOpenedAt: Date
    /// セキュリティスコープ付きブックマーク (サンドボックス対応)。nil でも動作する。
    let bookmark: Data?

    enum Kind: String, Codable {
        case project    // .captioncraft
    }

    var url: URL { URL(fileURLWithPath: path) }

    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
