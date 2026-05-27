import CoreMedia
import SwiftUI

// MARK: - CaptionListView

/// 全字幕エントリを一覧表示し、テキストと時間を直接編集できるリスト。
/// RightPanelView に CaptionPanel と並べて配置する。
///
/// 成熟度: experimental
struct CaptionListView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var playback: PlaybackController
    @ObservedObject var correctionService: CorrectionService
    @ObservedObject var translationService: TranslationService
    @ObservedObject var dictionaryStore: DictionaryStore
    var llmEndpoint: URL

    static func intent() -> String {
        """
        役割: 全字幕のリスト表示と一括編集 UI。
              SRT 的な「番号・タイムコード・テキスト」を縦に並べて編集する。
              右クリックでLLM校正・翻訳・ループ再生のコンテキストメニューを表示。
        成熟度: experimental
        依存: ProjectStore, PlaybackController, CorrectionService, TranslationService, DictionaryStore
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if regions.isEmpty {
                emptyState
            } else {
                regionList
            }
        }
    }

    private var regions: [CaptionRegion] {
        store.project?.editor.captionRegions ?? []
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("字幕一覧")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EditorTheme.textPrimary)

            Spacer()

            Text("\(regions.count) 件")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(EditorTheme.textSecondary)

            Button {
                addAtCurrentPosition()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(L10n.CaptionList.addAtPosition)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("字幕がありません")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(L10n.CaptionList.empty)
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Region list

    private var regionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                    CaptionRowView(
                        index: index + 1,
                        region: region,
                        onUpdate: { updated in
                            updateRegion(updated)
                        },
                        onDelete: {
                            deleteRegion(id: region.id)
                        },
                        onSeek: {
                            seekTo(ms: region.startMs)
                        },
                        onCorrect: {
                            correctSingleRegion(at: index)
                        },
                        onTranslate: {
                            translateSingleRegion(region)
                        },
                        onLoopPlay: {
                            let startSec = Double(region.startMs) / 1000.0
                            let endSec = Double(region.endMs) / 1000.0
                            playback.startSlowLoop(regionStartSec: startSec, regionEndSec: endSec)
                        },
                        onLoopStop: {
                            playback.stopSlowLoop()
                        },
                        isLooping: playback.isSlowLooping,
                        isCorrecting: correctionService.isRunning,
                        isTranslating: translationService.isTranslating
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func addAtCurrentPosition() {
        let currentMs = {
            let s = playback.currentTime.seconds
            return s.isFinite ? max(0, Int(s * 1000)) : 0
        }()

        var state = store.project?.editor ?? EditorState()
        let newRegion = CaptionRegion(
            startMs: currentMs,
            endMs: currentMs + 3000,
            text: "",
            isManuallyEdited: true,
            sourceLanguage: state.captionSettings.language,
            confidence: 1.0
        )
        state.captionRegions.append(newRegion)
        state.captionRegions.sort { $0.startMs < $1.startMs }
        store.commitState(state)
    }

    private func updateRegion(_ region: CaptionRegion) {
        guard var state = store.project?.editor else { return }
        guard let idx = state.captionRegions.firstIndex(where: { $0.id == region.id }) else { return }
        state.captionRegions[idx] = region
        store.commitState(state)
    }

    private func deleteRegion(id: UUID) {
        guard var state = store.project?.editor else { return }
        state.captionRegions.removeAll { $0.id == id }
        store.commitState(state)
    }

    private func seekTo(ms: Int) {
        let time = CMTime(value: Int64(ms), timescale: 1000)
        Task { await playback.seek(to: time) }
    }

    private func correctSingleRegion(at index: Int) {
        let regions = self.regions
        guard index >= 0, index < regions.count else { return }
        let domainHints = store.project?.editor.captionSettings.domainHints ?? []
        let dictionary = dictionaryStore.dictionary

        Task {
            do {
                var targetRegion = regions[index]
                if !dictionary.entries.isEmpty {
                    let (correctedBatch, appliedIDs) = DictionaryCorrector.apply(
                        dictionary: dictionary, to: [targetRegion]
                    )
                    targetRegion = correctedBatch[0]
                    for entryID in appliedIDs {
                        dictionaryStore.incrementUseCount(id: entryID)
                    }
                }
                var allHints = domainHints
                for entry in dictionary.entries {
                    allHints.append("\(entry.wrong)→\(entry.correct)")
                }
                var regionsForLLM = regions
                regionsForLLM[index] = targetRegion
                let client = LLMClient(endpoint: llmEndpoint)
                let corrected = try await correctionService.correctSingle(
                    targetIndex: index, allRegions: regionsForLLM,
                    domainHints: allHints, client: client
                )
                guard var state = store.project?.editor,
                      let stateIdx = state.captionRegions.firstIndex(where: { $0.id == corrected.id }) else { return }
                state.captionRegions[stateIdx] = corrected
                store.commitState(state)
            } catch {
                AppLog.caption.error("単体 LLM 校正失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func translateSingleRegion(_ region: CaptionRegion) {
        let allRegions = self.regions
        Task {
            do {
                let translated = try await translationService.translateSingle(
                    region, context: allRegions
                )
                guard var state = store.project?.editor,
                      let idx = state.captionRegions.firstIndex(where: { $0.id == translated.id }) else { return }
                state.captionRegions[idx] = translated
                store.commitState(state)
            } catch {
                translationService.lastError = error.localizedDescription
            }
        }
    }
}

// MARK: - CaptionRowView

/// 字幕 1 件分の表示・編集行。
struct CaptionRowView: View {
    let index: Int
    let region: CaptionRegion
    let onUpdate: (CaptionRegion) -> Void
    let onDelete: () -> Void
    let onSeek: () -> Void
    var onCorrect: (() -> Void)? = nil
    var onTranslate: (() -> Void)? = nil
    var onLoopPlay: (() -> Void)? = nil
    var onLoopStop: (() -> Void)? = nil
    var isLooping: Bool = false
    var isCorrecting: Bool = false
    var isTranslating: Bool = false

    @State private var editingText: String = ""
    @State private var isEditing: Bool = false
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(index)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(EditorTheme.textSecondary)
                    .frame(width: 24, alignment: .trailing)

                Button(action: onSeek) {
                    Text("\(SRTCodec.formatTime(region.startMs)) → \(SRTCodec.formatTime(region.endMs))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
                .help(L10n.CaptionList.seekTo)

                Spacer()

                if region.confidence < 0.6 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.CaptionList.deleteSubtitle)
            }

            if isEditing {
                TextEditor(text: $editingText)
                    .focused($textFocused)
                    .font(.system(size: 12))
                    .frame(minHeight: 36, maxHeight: 80)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.3))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.cyan.opacity(0.5), lineWidth: 1)
                    )
                    .onAppear { textFocused = true }
                    .onChange(of: textFocused) { focused in
                        if !focused {
                            commitEdit()
                        }
                    }
                    .onSubmit {
                        commitEdit()
                    }
            } else {
                Text(region.text.isEmpty ? "(空)" : region.text)
                    .font(.system(size: 12))
                    .foregroundStyle(region.text.isEmpty ? .secondary : EditorTheme.textPrimary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 30)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingText = region.text
                        isEditing = true
                    }
                    .contextMenu {
                        if let onCorrect {
                            Button(L10n.CaptionList.llmCorrection) { onCorrect() }
                                .disabled(isCorrecting)
                        }
                        if let onTranslate {
                            Button(L10n.CaptionList.translate) { onTranslate() }
                                .disabled(isTranslating)
                        }
                        if isLooping {
                            if let onLoopStop {
                                Button("ループ停止") { onLoopStop() }
                            }
                        } else {
                            if let onLoopPlay {
                                Button("ループ再生") { onLoopPlay() }
                            }
                        }
                        Divider()
                        Button(L10n.CaptionList.deleteSubtitle, role: .destructive) { onDelete() }
                    }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(index % 2 == 0 ? Color.white.opacity(0.02) : Color.clear)
        )
    }

    private func commitEdit() {
        isEditing = false
        guard editingText != region.text else { return }
        var updated = region
        updated.text = editingText
        updated.isManuallyEdited = true
        updated.confidence = 1.0
        onUpdate(updated)
    }
}
