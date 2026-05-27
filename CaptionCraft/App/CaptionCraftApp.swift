import AppKit
import SwiftUI

@main
struct CaptionCraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // メインウィンドウは AppDelegate で管理するため空
        // (エディターは NSWindow で別途起動)。
        // Settings scene は macOS 標準の Preferences ウィンドウ (⌘, / メニュー
        // "CaptionCraft → Settings…") を提供する。中身は PreferencesView (TabView)。
        Settings {
            PreferencesView()
        }
        .commands {
            CaptionCraftCommands()
        }
    }
}

// MARK: - Main menu commands

/// File / Edit メニューの追加コマンド。
/// SwiftUI の `.commands` ブロックから参照する。
/// 実体のディスパッチは `AppDelegate.shared` を経由してキーウィンドウのエディターに向ける。
struct CaptionCraftCommands: Commands {
    var body: some Commands {
        // アプリメニュー: 「CaptionCraft について」
        CommandGroup(replacing: .appInfo) {
            Button(L10n.App.about) {
                AboutWindowController.shared.show()
            }
        }

        // File メニュー: プロジェクト操作 → メディア入力 → SRT 入出力
        CommandGroup(replacing: .newItem) {
            // --- プロジェクト操作 ---
            Button(L10n.App.newProject) {
                Task { @MainActor in
                    AppDelegate.shared?.createNewProject()
                }
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button(L10n.App.openProject) {
                AppDelegate.shared?.presentOpenProjectPanel()
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
        CommandGroup(after: .newItem) {
            RecentDocumentsMenu()

            Divider()

            Button(L10n.App.saveProject) {
                AppDelegate.shared?.frontmostEditor?.performSave()
            }
            .keyboardShortcut("s", modifiers: [.command])

            Button(L10n.App.saveProjectAs) {
                AppDelegate.shared?.frontmostEditor?.performSaveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            // --- メディア入力 ---
            Button(L10n.App.openVideo) {
                AppDelegate.shared?.presentOpenVideoPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button(L10n.App.openYouTubeURL) {
                AppDelegate.shared?.openYouTubeURL()
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])

            Divider()

            // --- SRT 入出力 ---
            Button(L10n.App.importSRT) {
                AppDelegate.shared?.frontmostEditor?.performImportSRT()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button(L10n.App.exportSRT) {
                AppDelegate.shared?.frontmostEditor?.performExportSRT()
            }
            .keyboardShortcut("e", modifiers: [.command])
        }

        // Edit メニュー: Undo / Redo
        CommandGroup(replacing: .undoRedo) {
            Button(L10n.App.undo) {
                AppDelegate.shared?.frontmostEditor?.performUndo()
            }
            .keyboardShortcut("z", modifiers: [.command])

            Button(L10n.App.redo) {
                AppDelegate.shared?.frontmostEditor?.performRedo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Recent Documents submenu

/// File メニュー内の「最近使った書類」サブメニュー。
struct RecentDocumentsMenu: View {
    @ObservedObject private var manager = RecentDocumentsManager.shared

    var body: some View {
        Menu(L10n.App.recentDocuments) {
            if manager.recentFiles.isEmpty {
                Text(L10n.App.noRecentDocuments)
                    .foregroundColor(.secondary)
            } else {
                ForEach(manager.recentFiles) { doc in
                    Button(action: { openRecent(doc) }) {
                        Text(doc.name)
                    }
                }
                Divider()
                Button(L10n.App.clearRecentDocuments) {
                    RecentDocumentsManager.shared.clearAll()
                }
            }
        }
    }

    private func openRecent(_ doc: RecentDocument) {
        AppDelegate.shared?.openFile(at: doc.url)
    }
}
