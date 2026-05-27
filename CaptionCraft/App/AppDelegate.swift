import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// CaptionCraft のアプリケーションデリゲート。
///
/// 責務:
/// - エディタウィンドウのライフサイクル管理 (open / persist last opened / 終了時保存)
/// - File → Open メニューと OpenPanel
/// - 単一インスタンス用の `shared` 公開
///
/// 起動 UI はドキュメントベース: 前回のプロジェクトを自動再オープンし、無ければ
/// 空エディタを表示する。
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private(set) var editorWindowControllers: [EditorWindowController] = []

    /// 最後に開いていたプロジェクトのパスを保存するキー。
    /// 起動時に自動で再オープンするために使う。パッケージが移動 / 削除されていた場合は無視する。
    /// 複数ウィンドウ運用はまだしていないので「最後に前面だった 1 つ」だけ覚える。
    private static let lastOpenedProjectPathKey = "CaptionCraft.lastOpenedProjectPath.v1"

    /// SwiftUI `.commands { }` から参照するためのシングルトン。
    /// アプリ起動時に `applicationDidFinishLaunching` で設定される。
    static private(set) weak var shared: AppDelegate?

    /// 現在キーウィンドウになっているエディターを返す。
    /// メニュー操作（Save / Undo 等）のディスパッチに使う。
    var frontmostEditor: EditorWindowController? {
        if let key = editorWindowControllers.first(where: { $0.window?.isKeyWindow == true }) {
            return key
        }
        if let main = editorWindowControllers.first(where: { $0.window?.isMainWindow == true }) {
            return main
        }
        return editorWindowControllers.last
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        AppLog.app.info("CaptionCraft 起動")
        NSApp.setActivationPolicy(.regular)

        // コマンドライン引数でファイルパスが渡されていれば優先して開く。
        // 使い方: run.sh restart --open "/path/to/file.captioncraft"
        let args = ProcessInfo.processInfo.arguments
        if args.count >= 2 {
            let candidate = args[args.count - 1]
            let url = URL(fileURLWithPath: candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                AppLog.app.info("コマンドライン引数でファイルを開く: \(candidate, privacy: .public)")
                openFile(at: url)
                return
            }
        }

        reopenLastProjectIfAvailable()

        if editorWindowControllers.isEmpty {
            Task { @MainActor in
                openEmptyEditor()
            }
        }
    }

    /// 動画未読み込みの空エディタウィンドウを開く。
    @MainActor
    func openEmptyEditor() {
        let controller = EditorWindowController()
        presentEditor(controller)
    }

    // MARK: - 外部からのファイルオープン (open コマンド / Finder ダブルクリック)

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        openFile(at: url)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            openFile(at: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 全ウィンドウが閉じられても terminate しない (Dock 経由の再オープンを許可)。
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 未保存の変更があるエディターが 1 つでもあれば確認ダイアログを出す。
        let dirtyControllers = editorWindowControllers.filter { $0.store.isDirty }
        guard !dirtyControllers.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = L10n.App.unsavedTitle
        if dirtyControllers.count == 1 {
            let name = dirtyControllers[0].store.project?.name ?? "Project"
            alert.informativeText = L10n.App.unsavedSingle(name)
        } else {
            alert.informativeText = L10n.App.unsavedMultiple(dirtyControllers.count)
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.App.saveAndQuit)
        alert.addButton(withTitle: L10n.App.quitWithoutSaving)
        alert.addButton(withTitle: L10n.Common.cancel)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // 全 dirty エディターを保存
            for controller in dirtyControllers {
                if !controller.performSave() {
                    // 保存失敗 or キャンセル → 終了を中止
                    return .terminateCancel
                }
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save As などで savedURL が変わっている可能性があるため、終了直前に
        // 最前面エディターの現在 URL を再度永続化する。
        // frontmostEditor が nil (エディターを全て閉じた状態) なら、クリアはせず
        // 「最後に開いていた」記録を保持し続ける (次回も直前プロジェクトが開く)。
        if let url = frontmostEditor?.store.savedURL {
            persistLastOpenedProject(url: url)
        }
    }

    // MARK: - Last project auto-reopen

    /// 前回終了時に開いていたプロジェクトがあれば開く。
    /// `scripts/run.sh restart` などで編集セッションが中断された際、ユーザーが
    /// File → Open を手操作せずに作業を継続できるようにするため。
    private func reopenLastProjectIfAvailable() {
        guard let path = UserDefaults.standard.string(forKey: Self.lastOpenedProjectPathKey),
              !path.isEmpty
        else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 削除・移動された場合はキーをクリアしておく。
            UserDefaults.standard.removeObject(forKey: Self.lastOpenedProjectPathKey)
            return
        }
        openFile(at: url)
    }

    /// 現在のエディターの savedURL を UserDefaults に書き込む。
    /// presentEditor (開いた直後) とアプリ終了時の 2 点で呼ぶ。
    private func persistLastOpenedProject(url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: Self.lastOpenedProjectPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastOpenedProjectPathKey)
        }
    }

    // MARK: - New project

    /// メインメニュー「ファイル → 新規プロジェクト」(Cmd+N) から呼ばれる。
    /// 動画未読み込みの空エディタウィンドウを新しく開く。
    @MainActor
    func createNewProject() {
        openEmptyEditor()
    }

    // MARK: - Open file

    /// YouTube URL を入力してエディターを開く。
    func openYouTubeURL() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "YouTube URL を開く"
        alert.informativeText = "YouTube の動画 URL を入力してください"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "開く")
        alert.addButton(withTitle: "キャンセル")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        input.placeholderString = "https://www.youtube.com/watch?v=..."
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let urlText = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.isEmpty else { return }
        guard YouTubeURLValidator.extractVideoID(urlText) != nil else {
            let err = NSAlert()
            err.messageText = "無効な YouTube URL"
            err.informativeText = "有効な YouTube URL を入力してください (youtube.com/watch?v=, youtu.be/ 等)"
            err.alertStyle = .warning
            err.runModal()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let controller = EditorWindowController(youtubeURL: urlText)
            self.presentEditor(controller)
        }
    }

    /// メインメニュー「ファイル → プロジェクトを開く…」(Cmd+O) から呼ばれる。
    /// NSOpenPanel を出してプロジェクトファイル (.captioncraft) を選択させる。
    func presentOpenProjectPanel() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = L10n.App.selectProject
        panel.level = .modalPanel

        var types: [UTType] = []
        if let captioncraft = UTType(filenameExtension: "captioncraft") {
            types.append(captioncraft)
        }
        panel.allowedContentTypes = types

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openFile(at: url)
        }
    }

    /// メインメニュー「ファイル → 動画を開く…」(Shift+Cmd+O) から呼ばれる。
    /// NSOpenPanel を出して動画ファイルを選択させる。
    func presentOpenVideoPanel() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = L10n.App.selectVideo
        panel.level = .modalPanel

        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openFile(at: url)
        }
    }

    /// ACP 等から YouTube URL をダイアログなしで開く
    func openYouTubeURL(_ urlStr: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let controller = EditorWindowController(youtubeURL: urlStr)
            self.presentEditor(controller)
        }
    }

    /// 渡された URL をエディターで開く。
    /// 動画未読み込みの空ウィンドウがあればそこに流し込み、なければ新規ウィンドウを作る。
    func openFile(at url: URL) {
        let ext = url.pathExtension.lowercased()
        AppLog.file.info("ファイル open: \(url.lastPathComponent, privacy: .public) ext=\(ext, privacy: .public)")
        Task { @MainActor [weak self] in
            guard let self else { return }

            // 空のエディタウィンドウがあればそこに読み込む
            let emptyEditor = self.editorWindowControllers.first(where: { $0.isEmpty })

            if ext == "captioncraft" {
                do {
                    if let editor = emptyEditor {
                        try editor.loadProject(url: url)
                        editor.window?.makeKeyAndOrderFront(nil)
                        self.persistLastOpenedProject(url: editor.store.savedURL)
                    } else {
                        let controller = try EditorWindowController(projectURL: url)
                        self.presentEditor(controller)
                    }
                    RecentDocumentsManager.shared.noteOpened(url: url, kind: .project)
                } catch {
                    AppLog.file.error("プロジェクト読み込み失敗: \(error.localizedDescription, privacy: .public)")
                    NSApp.presentError(error)
                }
            } else {
                if let editor = emptyEditor {
                    editor.loadVideo(url: url)
                    editor.window?.makeKeyAndOrderFront(nil)
                    self.persistLastOpenedProject(url: editor.store.savedURL)
                } else {
                    let controller = EditorWindowController(videoURL: url)
                    self.presentEditor(controller)
                }
            }
        }
    }

    @MainActor
    private func presentEditor(_ controller: EditorWindowController) {
        editorWindowControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        // 起動時に再オープンするためのパスを記録する。
        // Save As で savedURL が変わった場合は applicationWillTerminate で再保存する。
        persistLastOpenedProject(url: controller.store.savedURL)

        if let window = controller.window {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object:  window,
                queue:   .main
            ) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.editorWindowControllers.removeAll { $0 === controller }
            }
        }
    }
}
