import SwiftUI

// MARK: - RightPanelTab

enum RightPanelTab: CaseIterable, Identifiable {
    case transcription
    case translation
    case correction
    case dictionary

    var id: Self { self }

    var icon: String {
        switch self {
        case .transcription: return "captions.bubble"
        case .translation:   return "globe"
        case .correction:    return "wand.and.stars"
        case .dictionary:    return "character.book.closed"
        }
    }

    var label: String {
        switch self {
        case .transcription: return "文字起こし"
        case .translation:   return L10n.Panel.translation
        case .correction:    return L10n.Panel.correction
        case .dictionary:    return "辞書"
        }
    }
}

// MARK: - RightPanelView

/// エディタウィンドウ右側のパネル。
/// 縦アイコンツールバーで「文字起こし / 翻訳 / 校正 / 辞書」を切り替える。
struct RightPanelView: View {
    @ObservedObject var store:              ProjectStore
    @ObservedObject var timeline:           TimelineViewModel
    @ObservedObject var captionTranscriber: CaptionTranscriber
    @ObservedObject var playback:           PlaybackController
    @ObservedObject var dictionaryStore:    DictionaryStore
    @ObservedObject var correctionService:  CorrectionService
    @ObservedObject var translationService: TranslationService

    @State private var selectedTab: RightPanelTab = .transcription

    var body: some View {
        HStack(spacing: 0) {
            tabBar
            Divider().background(EditorTheme.divider)
            tabContent
        }
        .background(EditorTheme.chrome)
        .onChange(of: translationService.endpoint) { newEndpoint in
            captionTranscriber.llmEndpoint = newEndpoint
        }
    }

    // MARK: - Tab bar (縦アイコンツールバー)

    private var tabBar: some View {
        VStack(spacing: 2) {
            ForEach(RightPanelTab.allCases) { tab in
                tabBarButton(tab)
            }
            Spacer()
        }
        .frame(width: 36)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.15))
    }

    private func tabBarButton(_ tab: RightPanelTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tab.label)
    }

    // MARK: - Tab content

    private var tabContent: some View {
        ScrollView {
            Group {
                switch selectedTab {
                case .transcription: transcriptionContent
                case .translation:   translationContent
                case .correction:    correctionContent
                case .dictionary:    dictionaryContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 文字起こしタブ

    private var transcriptionContent: some View {
        CaptionPanel(
            store: store,
            timeline: timeline,
            transcriber: captionTranscriber,
            playback: playback,
            dictionaryStore: dictionaryStore
        )
        .padding(16)
    }

    // MARK: - 翻訳タブ

    private var translationContent: some View {
        TranslationPanel(
            store: store,
            translator: translationService
        )
        .padding(16)
    }

    // MARK: - 校正タブ

    private var correctionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            correctionControls
                .padding(16)

            Divider().background(EditorTheme.divider)

            CorrectionHistoryView(store: store)
                .padding(16)
        }
    }

    @ViewBuilder
    private var correctionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Panel.llmCorrection)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EditorTheme.textPrimary)

            if correctionService.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(correctionService.progress)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    performLLMCorrection()
                } label: {
                    Label(L10n.Panel.runCorrection, systemImage: "wand.and.stars")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasRegions)
                .help(L10n.Panel.correctionHelp)
            }

            if let error = correctionService.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - 辞書タブ

    private var dictionaryContent: some View {
        DictionaryManagerView(
            dictionaryStore: dictionaryStore,
            store: store
        )
        .padding(16)
    }

    // MARK: - Correction logic (CaptionPanel から移動)

    private var hasRegions: Bool {
        !(store.project?.editor.captionRegions ?? []).isEmpty
    }

    private func performLLMCorrection() {
        guard let regions = store.project?.editor.captionRegions, !regions.isEmpty else { return }
        let hints = store.project?.editor.captionSettings.domainHints ?? []
        let client = LLMClient(endpoint: translationService.endpoint)
        let regionIDs = Set(regions.map { $0.id })

        captionTranscriber.correctionInFlight.formUnion(regionIDs)

        Task {
            defer {
                Task { @MainActor [weak captionTranscriber] in
                    captionTranscriber?.correctionInFlight.subtract(regionIDs)
                }
            }
            do {
                let corrected = try await correctionService.correct(
                    regions: regions,
                    domainHints: hints,
                    client: client
                ) { partial in
                    var state = store.project?.editor ?? EditorState()
                    state.captionRegions = partial
                    store.updateState(state)
                    // 部分完了したリージョンをスピナーから外す
                    let partialIDs = Set(partial.map { $0.id })
                    let doneIDs = regionIDs.intersection(partialIDs)
                    captionTranscriber.correctionInFlight.subtract(doneIDs)
                }
                var state = store.project?.editor ?? EditorState()
                state.captionRegions = corrected
                store.commitState(state)
            } catch {
                correctionService.lastError = error.localizedDescription
            }
        }
    }
}
