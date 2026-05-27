import AppKit
import AVFoundation
import Combine
import SwiftUI

/// プロジェクトを開く / 動画ファイルを読み込むエントリから生成されるエディターウィンドウ。
///
/// CC Phase 02 で `init(session: CompletedSession, ...)` (録画完了直後の autosave エントリ)
/// を削除した。CaptionCraft では既存動画ファイルから字幕を起こすフローのみを扱う。
@MainActor
final class EditorWindowController: NSWindowController {

    static func intent() -> String {
        return """
        役割: Editor ウィンドウのライフサイクル管理。プロジェクトファイルまたは動画ファイル
        のいずれかを入口に、ProjectStore + PlaybackController + TimelineViewModel を束ね、
        VideoEditorView をホストする NSWindow を提供する。閉じる際の dirty 確認もここで行う。

        成熟度: stable
        → 呼び出し側 (AppDelegate, メニューコマンド) が依存する公開 API は変更しない。

        触ってはいけない:
        - frameAutosaveName の識別子 "CaptionCraft.EditorWindow"
          (UserDefaults キーに直結、変えると保存済みの位置/サイズが失われる)

        変更時の注意:
        - makeWindow() で setFrameUsingName() → setFrameAutosaveName() の順序を守る。
          先に autosave name を設定すると center() との組み合わせで挙動が不安定になる。
        - NSWindow の frame autosave は frame 変化時に自動で UserDefaults に書き込む。
          追加の明示的な保存ロジックは不要。
        """
    }

    // MARK: - Properties

    let store:    ProjectStore
    let playback: PlaybackController
    let timeline: TimelineViewModel

    /// `store.project` を購読して `window.title` に反映するための Cancellable。
    private var titleSubscription: AnyCancellable?

    /// `store.isDirty` を購読してウィンドウの編集済みマーク (●) に反映する。
    private var dirtySubscription: AnyCancellable?

    /// トランスポート用キーボードショートカットのモニター。
    private var keyMonitor: Any?

    // MARK: - Init (empty — no video loaded)

    convenience init() {
        self.init(emptyWithPlaceholderVideo: nil)
    }

    // MARK: - Init (from a .captioncraft project package)

    convenience init(projectURL: URL) throws {
        self.init(emptyWithPlaceholderVideo: nil)
        try store.load(from: projectURL)
        guard let screenPath = store.project?.media.screenVideoPath else {
            throw FileError.packageCorrupted(reason: "screenVideoPath missing")
        }
        let videoURL = URL(fileURLWithPath: screenPath)
        Task { @MainActor [playback] in
            await playback.load(url: videoURL)
        }
    }

    // MARK: - Init (from a raw video file)

    convenience init(videoURL: URL) {
        self.init(emptyWithPlaceholderVideo: videoURL)
    }

    // MARK: - Init (YouTube mode)

    convenience init(youtubeURL: String) {
        self.init(emptyWithPlaceholderVideo: nil)
        let project = CaptionCraftProject(
            name: "YouTube",
            media: MediaPaths(screenVideoPath: "", youtubeURL: youtubeURL),
            editor: EditorState()
        )
        store.load(project: project)
    }

    // MARK: - 空ウィンドウへの動画流し込み

    /// 動画未読み込みの空ウィンドウかどうか。
    var isEmpty: Bool { !playback.hasVideo && store.project == nil && !(store.project?.media.isYouTubeMode ?? false) }

    /// 空ウィンドウに動画を後から読み込ませる。
    func loadVideo(url: URL) {
        let project = CaptionCraftProject(
            name: url.deletingPathExtension().lastPathComponent,
            media: MediaPaths(screenVideoPath: url.path),
            editor: EditorState()
        )
        store.load(project: project)
        Task { @MainActor [playback] in
            await playback.load(url: url)
        }
    }

    /// 空ウィンドウにプロジェクトを後から読み込ませる。
    func loadProject(url: URL) throws {
        try store.load(from: url)
        guard let screenPath = store.project?.media.screenVideoPath else {
            throw FileError.packageCorrupted(reason: "screenVideoPath missing")
        }
        let videoURL = URL(fileURLWithPath: screenPath)
        Task { @MainActor [playback] in
            await playback.load(url: videoURL)
        }
    }

    // MARK: - Shared init

    private init(emptyWithPlaceholderVideo videoURL: URL?) {
        self.store    = ProjectStore()
        self.playback = PlaybackController()
        self.timeline = TimelineViewModel()

        if let videoURL {
            let project = CaptionCraftProject(
                name: videoURL.deletingPathExtension().lastPathComponent,
                media: MediaPaths(screenVideoPath: videoURL.path),
                editor: EditorState()
            )
            store.load(project: project)
        }

        super.init(window: Self.makeWindow())
        finishSetup(loadVideoURL: videoURL)
    }

    required init?(coder: NSCoder) {
        fatalError("EditorWindowController does not support NSCoder")
    }

    // MARK: - Setup helpers

    /// UserDefaults に window frame を自動保存するためのキー。
    /// 変更すると保存済みの位置/サイズが失われるので触らない。
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("CaptionCraft.EditorWindow")

    private static func makeWindow() -> NSWindow {
        let window = ZoomableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer:   false
        )
        window.title = L10n.Editor.title
        window.minSize = NSSize(width: 900, height: 600)
        window.collectionBehavior.insert(.fullScreenPrimary)

        // 一体化トップバー。タイトル文字列は NSWindow のネイティブ title (titlebarAppears
        // Transparent な領域に OS が自動描画) を使う。TopToolbar 内には重複の Text を
        // 置かず、トップバーの中央は素通しにしてプロジェクト名を見せる。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(
            srgbRed: 0x0D/255.0, green: 0x0D/255.0, blue: 0x10/255.0, alpha: 1
        )

        if !window.setFrameUsingName(frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(frameAutosaveName)

        return window
    }

    /// NSWindow.title 用の文字列を作る。プロジェクトがあれば `<name>.captioncraft`、
    /// 無ければ既定のアプリタイトルを返す。
    private static func makeWindowTitle(for project: CaptionCraftProject?) -> String {
        if let name = project?.name, !name.isEmpty {
            return "\(name).captioncraft"
        }
        return L10n.Editor.titleUntitled
    }

    private func finishSetup(loadVideoURL: URL?) {
        let rootView = VideoEditorView(
            store:    store,
            playback: playback,
            timeline: timeline
        )
        let hostingView = TitleBarAwareHostingView(rootView: rootView)
        window?.contentView = hostingView
        window?.delegate = self

        // ACP: ウィンドウコントローラーをリモート制御サーバーに登録
        RemoteControlServer.shared.editorWindow = self

        // プロジェクト名の変化 (save-as 等) を NSWindow.title に反映する。
        titleSubscription = store.$project
            .receive(on: RunLoop.main)
            .sink { [weak self] project in
                self?.window?.title = Self.makeWindowTitle(for: project)
            }

        // 未保存変更があるときタイトルバーに ● を表示する。
        dirtySubscription = store.$isDirty
            .receive(on: RunLoop.main)
            .sink { [weak self] dirty in
                self?.window?.isDocumentEdited = dirty
            }

        playback.onMetadataLoaded = { [weak self] duration, size in
            self?.store.updateMediaMetadata(duration: duration, size: size)
        }

        if let loadVideoURL {
            Task { @MainActor [playback] in
                await playback.load(url: loadVideoURL)
            }
        }

        installTransportKeyMonitor()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// スペースキー: 再生/一時停止トグル、リターンキー: 停止（先頭に戻る）。
    /// テキスト入力フィールドにフォーカスがあるときは無視する。
    private func installTransportKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.window?.isKeyWindow == true else { return event }

            // テキスト編集中はショートカットを発火させない
            if let responder = self.window?.firstResponder,
               responder is NSTextView {
                return event
            }

            switch event.keyCode {
            case 49: // Space
                self.playback.toggle()
                return nil
            case 36: // Return
                self.playback.pause()
                Task { @MainActor [playback = self.playback] in
                    await playback.seek(to: 0)
                }
                return nil
            case 126: // ↑ 音量を上げる
                self.playback.player.volume = min(1.0, self.playback.player.volume + 0.1)
                return nil
            case 125: // ↓ 音量を下げる
                self.playback.player.volume = max(0.0, self.playback.player.volume - 0.1)
                return nil
            case 123: // ← 前のリージョンへ
                self.seekToPreviousRegion()
                return nil
            case 124: // → 次のリージョンへ
                self.seekToNextRegion()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Region navigation (keyboard)

    private func seekToPreviousRegion() {
        let regions = (store.project?.editor.captionRegions ?? []).sorted { $0.startMs < $1.startMs }
        guard !regions.isEmpty else { return }
        let ms = Int(playback.currentTime.seconds * 1000)
        let target = regions.last(where: { $0.startMs < ms - 100 }) ?? regions.first!
        Task { await playback.seek(to: Double(target.startMs) / 1000.0) }
    }

    private func seekToNextRegion() {
        let regions = (store.project?.editor.captionRegions ?? []).sorted { $0.startMs < $1.startMs }
        guard !regions.isEmpty else { return }
        let ms = Int(playback.currentTime.seconds * 1000)
        let target = regions.first(where: { $0.startMs > ms + 100 }) ?? regions.last!
        Task { await playback.seek(to: Double(target.startMs) / 1000.0) }
    }

    // MARK: - Menu actions (dispatched from App commands)

    @discardableResult
    func performSave() -> Bool {
        guard store.project != nil else { return false }
        if let url = store.savedURL {
            do {
                try store.save(to: url)
                RecentDocumentsManager.shared.noteOpened(url: url, kind: .project)
                return true
            } catch {
                NSApp.presentError(error)
                return false
            }
        }
        return performSaveAs()
    }

    @discardableResult
    func performSaveAs() -> Bool {
        guard store.project != nil else { return false }
        do {
            _ = try store.saveAs()
            if let url = store.savedURL {
                RecentDocumentsManager.shared.noteOpened(url: url, kind: .project)
            }
            return true
        } catch CocoaError.userCancelled {
            return false
        } catch let err as CocoaError where err.code == .userCancelled {
            return false
        } catch {
            NSApp.presentError(error)
            return false
        }
    }

    func performUndo() {
        guard store.canUndo else { return }
        store.undo()
    }

    func performRedo() {
        guard store.canRedo else { return }
        store.redo()
    }

    // MARK: - SRT Import / Export

    func performImportSRT() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.Editor.srtSelectFile
        if let srtType = UTType(filenameExtension: "srt") {
            panel.allowedContentTypes = [srtType]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let regions = try SRTCodec.load(from: url)
            guard !regions.isEmpty else {
                let alert = NSAlert()
                alert.messageText = L10n.Editor.srtNoSubtitlesTitle
                alert.informativeText = L10n.Editor.srtNoSubtitlesMessage
                alert.alertStyle = .warning
                alert.runModal()
                return
            }

            // 既存の字幕があれば上書き確認
            if let existing = store.project?.editor.captionRegions, !existing.isEmpty {
                let alert = NSAlert()
                alert.messageText = L10n.Editor.srtReplaceTitle
                alert.informativeText = L10n.Editor.srtReplaceMessage(existing: existing.count, imported: regions.count)
                alert.alertStyle = .warning
                alert.addButton(withTitle: L10n.Editor.srtReplace)
                alert.addButton(withTitle: L10n.Common.cancel)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }

            var state = store.project?.editor ?? EditorState()
            state.captionRegions = regions
            store.commitState(state)
        } catch {
            NSApp.presentError(error)
        }
    }

    func performExportSRT() {
        guard let regions = store.project?.editor.captionRegions, !regions.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L10n.Editor.srtNoExportTitle
            alert.informativeText = L10n.Editor.srtNoExportMessage
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(store.project?.name ?? "untitled").srt"
        panel.canCreateDirectories = true
        panel.message = L10n.Editor.srtSaveLocation
        if let srtType = UTType(filenameExtension: "srt") {
            panel.allowedContentTypes = [srtType]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try SRTCodec.save(regions, to: url)
        } catch {
            NSApp.presentError(error)
        }
    }
}

// MARK: - NSWindowDelegate (dirty close confirmation)

extension EditorWindowController: NSWindowDelegate {
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard let screen = window.screen else { return newFrame }
        return screen.visibleFrame
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store.isDirty else { return true }

        let alert = NSAlert()
        alert.messageText = L10n.Editor.closeSaveTitle
        alert.informativeText = L10n.Editor.closeSaveMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Editor.closeSave)
        alert.addButton(withTitle: L10n.Editor.closeDiscard)
        alert.addButton(withTitle: L10n.Common.cancel)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return performSave()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

// MARK: - TitleBarAwareHostingView

/// .fullSizeContentView + .titlebarAppearsTransparent を使うと、
/// NSHostingView がタイトルバー領域のダブルクリックを消費してしまい、
/// 標準の zoom（最大化/復元）が動作しなくなる。
/// このサブクラスはタイトルバー高さ以内のダブルクリックを検出して
/// performZoom を呼び、標準の macOS 動作を復元する。
final class TitleBarAwareHostingView<Content: View>: NSHostingView<Content> {
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            let locationInView = convert(event.locationInWindow, from: nil)
            let titleBarHeight = window?.contentLayoutRect.origin.y ?? 0
            let viewHeight = bounds.height
            if locationInView.y > viewHeight - titleBarHeight {
                window?.performZoom(nil)
                return
            }
        }
        super.mouseUp(with: event)
    }
}

/// タイトルバーのダブルクリックで zoom を発動させるカスタム NSWindow。
/// .fullSizeContentView + .titlebarAppearsTransparent の場合、OS 標準の
/// ダブルクリック→zoom が動作しないことがある。NSWindow レベルで
/// sendEvent をフックし、タイトルバー領域のダブルクリックを検出する。
final class ZoomableWindow: NSWindow {
    private var titleBarHeight: CGFloat {
        frame.height - contentLayoutRect.height
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp && event.clickCount == 2 {
            let loc = event.locationInWindow
            let contentHeight = contentView?.frame.height ?? frame.height
            let tbHeight = max(titleBarHeight, 28)
            if loc.y > contentHeight - tbHeight {
                zoom(nil)
                return
            }
        }
        super.sendEvent(event)
    }
}
