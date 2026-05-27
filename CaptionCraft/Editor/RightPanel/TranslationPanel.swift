import SwiftUI

// MARK: - TranslationPanel

/// 字幕の一括自動翻訳 UI。
/// LM Studio 等の OpenAI 互換 API に接続して翻訳する。
///
/// 成熟度: experimental
struct TranslationPanel: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var translator: TranslationService

    /// 翻訳先言語の選択肢
    private let targetLanguages: [(code: String, label: String)] = [
        ("en", "English"),
        ("ja", "日本語"),
        ("zh", "中文"),
        ("ko", "한국어"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("pt", "Português"),
        ("ru", "Русский"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.Translation.title)

            if translator.isFetchingModels {
                // 初回チェック中
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.Translation.fetching)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                switch translator.serverStatus {
                case .notInstalled:
                    serverStatusBanner(
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        title: L10n.Translation.notInstalled,
                        detail: L10n.Translation.notInstalledDetail
                    )
                    Link(destination: URL(string: "https://lmstudio.ai")!) {
                        Label(L10n.Translation.downloadLMStudio, systemImage: "arrow.down.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    refreshButton

                case .notRunning:
                    serverStatusBanner(
                        icon: "power",
                        color: .secondary,
                        title: L10n.Translation.notRunning,
                        detail: L10n.Translation.notRunningDetail
                    )
                    HStack(spacing: 8) {
                        Button {
                            LLMServerChecker.launchLMStudio()
                        } label: {
                            Label(L10n.Translation.launchLMStudio, systemImage: "play.circle")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        refreshButton
                    }

                case .noModelLoaded:
                    if translator.isAutoLoading, let modelID = translator.savedModelID {
                        // 自動ロード中
                        serverStatusBanner(
                            icon: "arrow.down.circle",
                            color: .blue,
                            title: L10n.Translation.autoLoading,
                            detail: modelID
                        )
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.Translation.autoLoadingWait)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        serverStatusBanner(
                            icon: "cube",
                            color: .yellow,
                            title: L10n.Translation.noModelLoaded,
                            detail: translator.savedModelID.map {
                                L10n.Translation.lastUsedModel($0)
                            } ?? L10n.Translation.noModelLoadedDetail
                        )
                        HStack(spacing: 8) {
                            if let modelID = translator.savedModelID {
                                Button {
                                    translator.autoLoadModel(id: modelID)
                                } label: {
                                    Label(L10n.Translation.loadLastModel, systemImage: "arrow.clockwise.circle")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            Button {
                                LLMServerChecker.launchLMStudio()
                            } label: {
                                Label(L10n.Translation.openLMStudio, systemImage: "arrow.up.forward.app")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            refreshButton
                        }
                    }

                case .connected:
                    connectedUI
                }
            }

            // エラー表示
            if let error = translator.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            }
        }
        .onAppear {
            translator.refreshModels()
        }
    }

    // MARK: - Connected state UI

    @ViewBuilder
    private var connectedUI: some View {
        // エンドポイント設定
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(L10n.Translation.server)
            TextField(L10n.Translation.serverPlaceholder, text: endpointBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { translator.refreshModels() }
        }

        // モデル選択
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel(L10n.Translation.model)
                Spacer()
                refreshButton
            }

            if translator.availableModels.isEmpty {
                Text(translator.isFetchingModels ? L10n.Translation.fetching : L10n.Translation.serverDisconnected)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                Picker("", selection: modelBinding) {
                    ForEach(translator.availableModels) { model in
                        Text(model.id)
                            .font(.system(size: 11))
                            .tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }

        // 翻訳先言語
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(L10n.Translation.targetLanguage)
            Picker("", selection: $translator.targetLanguage) {
                ForEach(targetLanguages, id: \.code) { lang in
                    Text(lang.label).tag(lang.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }

        // 翻訳ボタン / 進捗
        if translator.isTranslating {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(translator.progress)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Button {
                performTranslation()
            } label: {
                Label(L10n.Translation.translateAll, systemImage: "globe")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!hasRegions)
            .help(hasRegions ? "" : L10n.Translation.noSubtitles)
        }
    }

    // MARK: - Shared components

    private var refreshButton: some View {
        Button {
            translator.refreshModels()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(L10n.Translation.refreshModels)
    }

    private func serverStatusBanner(
        icon: String,
        color: Color,
        title: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(EditorTheme.textPrimary)
            }
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(EditorTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .cornerRadius(6)
    }

    private var hasRegions: Bool {
        guard let regions = store.project?.editor.captionRegions else { return false }
        return !regions.isEmpty
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { translator.selectedModelID ?? "" },
            set: { translator.selectedModelID = $0.isEmpty ? nil : $0 }
        )
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: { translator.endpoint.absoluteString },
            set: { newValue in
                if let url = URL(string: newValue) {
                    translator.endpoint = url
                }
            }
        )
    }

    private func performTranslation() {
        guard let regions = store.project?.editor.captionRegions, !regions.isEmpty else { return }

        Task {
            do {
                let translated = try await translator.translate(regions) { partial in
                    // バッチ完了ごとに画面を更新（翻訳結果がリアルタイムで見える）
                    var state = store.project?.editor ?? EditorState()
                    state.captionRegions = partial
                    store.updateState(state)
                    // 最後に翻訳された行へ自動スクロール
                    if let lastTranslated = partial.last(where: { $0.translatedText != nil }) {
                        store.scrollToRegionID = lastTranslated.id
                    }
                }
                // 全バッチ完了後に確定（undo 対象）
                var state = store.project?.editor ?? EditorState()
                state.captionRegions = translated
                store.commitState(state)
            } catch {
                translator.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - UI helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(EditorTheme.textPrimary)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(EditorTheme.textSecondary)
    }
}
