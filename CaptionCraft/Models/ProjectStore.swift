import AppKit
import Combine
import CoreMedia
import Foundation
import UniformTypeIdentifiers

// MARK: - FileError

enum FileError: LocalizedError {
    case noProjectLoaded
    case pathTraversalDetected
    case packageCorrupted(reason: String)
    case mediaFileMissing(path: String)

    var errorDescription: String? {
        switch self {
        case .noProjectLoaded:              return "No project is currently loaded."
        case .pathTraversalDetected:        return "Invalid file path detected."
        case .packageCorrupted(let reason): return "Project file is corrupted: \(reason)"
        case .mediaFileMissing(let path):   return "Media file not found: \(path)"
        }
    }
}

// MARK: - ProjectStore

/// CaptionCraft プロジェクトの状態管理 + 永続化。
///
/// CC Phase 03 で動画編集機能を全削除した結果、`AnnotationRegion` 等の helpers と
/// CursorTelemetry の load ロジックを除去した。`MediaPaths` のフィールドも
/// `screenVideoPath` のみに絞ったため、相対化 / 絶対化ロジックも 1 フィールドだけを
/// 扱うシンプルな実装に書き直している。
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var project: CaptionCraftProject?
    @Published private(set) var isDirty: Bool = false

    /// 字幕リストで自動スクロールしたいリージョンの ID。
    /// 翻訳バッチ完了時などに設定し、TimelineView 側で ScrollViewReader.scrollTo に使う。
    @Published var scrollToRegionID: UUID?

    /// saveAs 完了後に格納される、プロジェクトパッケージの URL。
    /// `Save` (Cmd+S) からの再保存先判定に使う。nil なら Save As にフォールバック。
    var savedURL: URL?

    private var past: [EditorState] = []
    private var future: [EditorState] = []
    private let maxHistory = 80

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - State mutations

    func updateState(_ state: EditorState) {
        guard project != nil else { return }
        project?.editor = state
        isDirty = true
    }

    func commitState(_ state: EditorState) {
        guard let current = project?.editor else { return }
        past.append(current)
        if past.count > maxHistory { past.removeFirst() }
        future.removeAll()
        project?.editor = state
        isDirty = true
    }

    func undo() {
        guard let current = project?.editor, let previous = past.popLast() else { return }
        future.append(current)
        project?.editor = previous
        isDirty = true
    }

    func redo() {
        guard let current = project?.editor, let next = future.popLast() else { return }
        past.append(current)
        if past.count > maxHistory { past.removeFirst() }
        project?.editor = next
        isDirty = true
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// E2E テスト用: 保存ダイアログを回避するために isDirty を強制クリアする。
    func clearDirty() { isDirty = false }

    // MARK: - In-memory load

    /// プロジェクトを取り込む (ディスク経由でない、in-memory 由来の load)。
    func load(project: CaptionCraftProject) {
        var p = project
        if p.editor.captionSettings == .default,
           PreferencesStore.shared.hasStoredWhisperSettings {
            p.editor.captionSettings = PreferencesStore.shared.loadWhisperSettings()
        }
        self.project = p
        past.removeAll()
        future.removeAll()
        isDirty = false
        savedURL = nil
    }

    /// AVAsset のロードが終わったあとに呼び、メディア寸法/長さを反映する。
    /// CC Phase 03 で originalWidth/Height は MediaPaths から削除したため、
    /// duration のみ書き戻す。
    func updateMediaMetadata(duration: CMTime, size: CGSize) {
        guard var p = self.project else { return }
        let seconds = duration.seconds
        if seconds.isFinite && seconds > 0 {
            p.media.durationMs = Int(seconds * 1000)
        }
        self.project = p
    }

    /// MediaPaths を直接更新する (YouTube モードのキャプチャパス設定等)。
    func updateMedia(_ media: MediaPaths) {
        guard var p = self.project else { return }
        p.media = media
        self.project = p
    }

    // MARK: - File I/O

    func load(from url: URL) throws {
        let jsonURL = url.appending(path: "project.json")
        let data = try Data(contentsOf: jsonURL)
        var loaded = try decoder.decode(CaptionCraftProject.self, from: data)
        // パッケージ同梱モード: 相対パスを package URL で絶対化する
        loaded.media = Self.absolutize(loaded.media, packageURL: url)
        var migrated = migrate(loaded)
        // ディスクから読んだプロジェクトは保存時の設定をそのまま使う。
        // UserDefaults で上書きすると、言語設定が変わって英語字幕が
        // 日本語扱いになるなどの混乱が起きる。
        project = migrated
        past.removeAll()
        future.removeAll()
        isDirty = false
        savedURL = url
    }

    func save(to url: URL) throws {
        guard var p = project else { throw FileError.noProjectLoaded }
        p.modifiedAt = Date()
        // パッケージ内に収まっているメディアは相対パスでシリアライズ
        let toDisk = Self.relativize(p.media, packageURL: url)
        var diskProject = p
        diskProject.media = toDisk
        let jsonURL = url.appending(path: "project.json")
        let data = try encoder.encode(diskProject)
        try data.write(to: jsonURL, options: .atomic)
        // in-memory は引き続き絶対パス (描画や再生に絶対パスが必要なので再読込不要)
        project = p
        isDirty = false
        savedURL = url
    }

    @discardableResult
    func saveAs() throws -> URL {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project?.name ?? "Untitled").captioncraft"
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the CaptionCraft project"

        guard panel.runModal() == .OK, let url = panel.url else {
            throw CocoaError(.userCancelled)
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let mediaDir = url.appending(path: "media")
        let assetsDir = url.appending(path: "assets")
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        try save(to: url)
        savedURL = url
        return url
    }

    // MARK: - Migration

    private func migrate(_ p: CaptionCraftProject) -> CaptionCraftProject {
        guard p.version < CaptionCraftProject.currentVersion else { return p }
        var migrated = p
        migrated.version = CaptionCraftProject.currentVersion
        return migrated
    }
}

// MARK: - Programmatic Save As (no NSSavePanel)

extension ProjectStore {
    /// 自動化用途の Save As。既存の `saveAs()` は NSSavePanel を出してしまうので、
    /// モーダルなしで「指定 URL に package を作って save」する内部 API。
    func saveAs(to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let mediaDir  = url.appending(path: "media")
        let assetsDir = url.appending(path: "assets")
        try fm.createDirectory(at: mediaDir,  withIntermediateDirectories: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try save(to: url)
    }
}

// MARK: - Autosave destination helpers

extension ProjectStore {
    /// 既定プロジェクト保存先 `~/Movies/CaptionCraft/Projects/` を返す。
    /// 存在しなければ作成する。
    static func defaultProjectsDirectory() throws -> URL {
        let fm = FileManager.default
        guard let movies = fm.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            throw FileError.packageCorrupted(reason: "Could not locate ~/Movies")
        }
        let dir = movies
            .appending(path: "CaptionCraft", directoryHint: .isDirectory)
            .appending(path: "Projects", directoryHint: .isDirectory)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 自動保存用パッケージ URL を組み立てる。
    /// 例: `~/Movies/CaptionCraft/Projects/<base-name>.captioncraft`
    ///
    /// - Note: `sessionName` にはパス区切り `/` が混ざりうるため `-` に置換する。
    static func autosaveURL(for sessionName: String) throws -> URL {
        let dir = try defaultProjectsDirectory()
        let safe = sessionName.replacingOccurrences(of: "/", with: "-")
        return dir.appending(path: "\(safe).captioncraft", directoryHint: .isDirectory)
    }
}

// MARK: - Package-embedded save/load helpers (パッケージ同梱モード)

extension ProjectStore {
    /// in-memory の絶対パスを package URL 基準の相対パスに書き換える。
    /// パッケージ外にあるファイル (legacy の `recordings/` 等) は絶対のまま残す。
    fileprivate static func relativize(_ m: MediaPaths, packageURL: URL) -> MediaPaths {
        var copy = m
        copy.screenVideoPath = Self.toRelative(m.screenVideoPath, base: packageURL) ?? m.screenVideoPath
        return copy
    }

    /// JSON から読み出した相対パスを絶対パスへ展開する。すでに絶対ならそのまま。
    fileprivate static func absolutize(_ m: MediaPaths, packageURL: URL) -> MediaPaths {
        var copy = m
        copy.screenVideoPath = Self.toAbsolute(m.screenVideoPath, base: packageURL)
        return copy
    }

    private static func toRelative(_ path: String, base: URL) -> String? {
        guard !path.isEmpty else { return nil }
        let basePath = base.standardizedFileURL.path.hasSuffix("/")
            ? base.standardizedFileURL.path
            : base.standardizedFileURL.path + "/"
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard target.hasPrefix(basePath) else { return nil }
        return String(target.dropFirst(basePath.count))
    }

    private static func toAbsolute(_ path: String, base: URL) -> String {
        // 既に絶対パスならそのまま
        if path.hasPrefix("/") { return path }
        return base.appending(path: path).path
    }
}
