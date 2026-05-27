import SwiftUI
import CoreMedia

// MARK: - CaptionPanel

/// Right panel の comment rail 内に表示する Caption 編集パネル。
/// - トラック全体操作: モデル/言語/無音閾値/全体合成/進捗
/// - 選択中 region 編集: テキスト / 時刻 / 単一再合成 / status
///
/// 成熟度: experimental (FIX_10 Phase 1)
struct CaptionPanel: View {
    @ObservedObject var store:             ProjectStore
    @ObservedObject var timeline:          TimelineViewModel
    @ObservedObject var transcriber:       CaptionTranscriber
    @ObservedObject var playback:          PlaybackController
    @ObservedObject var dictionaryStore:   DictionaryStore

    /// FIX_10 UX-B: TextEditor の draft。選択 region が切り替わるたびに同期し、
    /// 打鍵中は updateCaption (undo 履歴に載せない) で反映、blur で commitCaption
    /// (undo 履歴に載せる) する。
    @State private var draft: String = ""
    /// 現在編集対象の Caption UUID。別 region に切り替わった/選択解除されたら draft を再同期する。
    @State private var draftRegionID: UUID? = nil
    @FocusState private var textFocused: Bool
    /// 自動辞書学習: ユーザー編集時に検出された diff。
    @State private var pendingDiff: EditDiff? = nil
    /// 自動辞書学習: 同じ誤認識パターンが見つかった region 数。
    @State private var matchingRegionCount: Int = 0
    /// VAD キャリブレーション: 測定中の RMS 値
    @State private var calibQuietRMS: Float?
    @State private var calibLoudRMS: Float?
    @State private var calibMeasuring: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            trackSection
            Divider().background(EditorTheme.divider)
            selectedRegionSection
            dictionaryLearningBanner
        }
    }

    // MARK: - Track-level controls

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.Caption.whisperTitle)

            // 主言語 Picker
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(L10n.Caption.whisperLanguage)
                Picker("", selection: bindingSettings(keyPath: \.language)) {
                    ForEach(Self.supportedLanguages, id: \.code) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .e2eTrack(id: "editor.rightPanel.caption.languagePicker", role: "AXPopUpButton", label: "Caption language")
            }

            // 追加言語チェックマーク（多言語モード用）
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("追加言語（複数言語の動画）")
                let primary = settings.language
                let others = Self.supportedLanguages.filter { $0.code != primary && $0.code != "auto" }
                ForEach(others, id: \.code) { lang in
                    Toggle(lang.label, isOn: additionalLanguageBinding(lang.code))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .controlSize(.small)
                }
                if settings.isMultilingual && settings.language == "auto" {
                    Text("⚠ 多言語モードでは主言語を指定してください")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                } else if settings.isMultilingual {
                    Text("⚠ 多言語モード: 言語数×処理時間")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            // 無音閾値 Stepper
            HStack(spacing: 8) {
                fieldLabel(L10n.Caption.whisperSilenceThreshold)
                Spacer()
                Stepper(
                    value: bindingSettings(keyPath: \.silenceSplitMs),
                    in: 200...1000,
                    step: 50
                ) {
                    Text("\(settings.silenceSplitMs)")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }
                .controlSize(.small)
            }

            // 単語数分割 Stepper (CJK 以外の言語で有効)
            if settings.language != "ja" {
                HStack(spacing: 8) {
                    fieldLabel(L10n.Caption.whisperMaxWords)
                    Spacer()
                    Stepper(
                        value: bindingSettings(keyPath: \.maxWordsPerSegment),
                        in: 3...30,
                        step: 1
                    ) {
                        Text("\(settings.maxWordsPerSegment)")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                    .controlSize(.small)
                }
            }

            // LLM 校正の自動実行トグル
            Toggle("書き起こし後に LLM 校正を実行", isOn: bindingSettings(keyPath: \.autoCorrectWithLLM))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .controlSize(.small)
                .help("オンにすると書き起こし完了後に LLM で自動校正します。処理時間が増えます。")

            // 長リージョン自動分割トグル
            Toggle("長い字幕を自動分割", isOn: bindingSettings(keyPath: \.splitLongRegions))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .controlSize(.small)
                .help("オフにすると長い字幕をそのまま保持します。被せ喋りが多い動画ではオフ推奨。")

            // VAD 方式選択（「VADなし」は Whisper 系エンジンのみ表示）
            Picker("音声検出", selection: vadMethodBinding) {
                Text("音量ベース (高速)").tag(VADMethod.energy)
                Text("AI検出 (BGM/ノイズ耐性)").tag(VADMethod.silero)
                if PreferencesStore.shared.sttEngine.supportsNoVAD {
                    Text("VADなし (Whisper直接)").tag(VADMethod.none)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 11))
            .controlSize(.small)
            .help("音量ベース: 高速。AI検出: BGM/ノイズ耐性。VADなし: 30秒ずつWhisperに渡す (Whisper系のみ)。")

            // VAD 感度選択
            Picker("検出感度", selection: bindingSettings(keyPath: \.vadSensitivity)) {
                ForEach(VADSensitivity.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 11))
            .controlSize(.small)
            .help("高: 小さい音も拾う（誤検出増）。低: 確実な音声のみ検出（取りこぼし増）。")

            // VAD キャリブレーション（音量ベースのみ有効）
            if settings.vadMethod == .energy {
                vadCalibrationSection
            }

            // 全体合成ボタン / 進捗
            autoTranscribeControl
        }
    }

    // MARK: - VAD キャリブレーション

    @ViewBuilder
    private var vadCalibrationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("音量キャリブレーション")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if let cal = settings.vadCalibration {
                HStack(spacing: 8) {
                    Label(String(format: "小声 %.4f", cal.quietRMS), systemImage: "speaker.wave.1")
                    Label(String(format: "大声 %.4f", cal.loudRMS), systemImage: "speaker.wave.3")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Text("再生ヘッドの前後0.2秒を測定します")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                Button {
                    measureCalibration(isQuiet: true)
                } label: {
                    Label("小声を測定", systemImage: "speaker.wave.1")
                }
                .disabled(calibMeasuring)

                Button {
                    measureCalibration(isQuiet: false)
                } label: {
                    Label("大声を測定", systemImage: "speaker.wave.3")
                }
                .disabled(calibMeasuring)
            }
            .font(.system(size: 11))
            .controlSize(.small)

            HStack(spacing: 8) {
                if let q = calibQuietRMS, let l = calibLoudRMS {
                    Button("適用") {
                        applyCalibration(quietRMS: q, loudRMS: l)
                    }
                    .controlSize(.small)
                    .font(.system(size: 11))

                    Text(String(format: "小声 %.4f / 大声 %.4f", q, l))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if settings.vadCalibration != nil {
                    Button("リセット") {
                        clearCalibration()
                        calibQuietRMS = nil
                        calibLoudRMS = nil
                    }
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private func measureCalibration(isQuiet: Bool) {
        guard let project = store.project else { return }
        let currentMs = Int(CMTimeGetSeconds(playback.currentTime) * 1000)
        let startMs = max(0, currentMs - 200)
        let endMs = min(project.media.durationMs, currentMs + 200)
        guard endMs > startMs else { return }

        let audioPath = project.media.capturedAudioPath ?? project.media.screenVideoPath
        let url = URL(fileURLWithPath: audioPath)

        calibMeasuring = true
        Task {
            do {
                let rms = try await CaptionTranscriber.measureRMS(
                    url: url, startMs: startMs, endMs: endMs
                )
                await MainActor.run {
                    if isQuiet {
                        calibQuietRMS = rms
                    } else {
                        calibLoudRMS = rms
                    }
                    calibMeasuring = false
                }
            } catch {
                await MainActor.run { calibMeasuring = false }
                AppLog.caption.error("キャリブレーション測定失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyCalibration(quietRMS: Float, loudRMS: Float) {
        guard var state = store.project?.editor else { return }
        state.captionSettings.vadCalibration = VADCalibration(
            quietRMS: quietRMS, loudRMS: loudRMS
        )
        store.commitState(state)
    }

    private func clearCalibration() {
        guard var state = store.project?.editor else { return }
        state.captionSettings.vadCalibration = nil
        store.commitState(state)
    }

    @ViewBuilder
    private var autoTranscribeControl: some View {
        switch transcriber.status {
        case .idle:
            Button {
                transcriber.retranscribeAll(store: store)
            } label: {
                Label(L10n.Caption.whisperSynthesizeAll, systemImage: "captions.bubble")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!hasAudioSource)
            .help(hasAudioSource ? "" : L10n.Caption.whisperNoVideo)

        case .loadingModel(let p, let msg):
            progressRow(
                label: msg.isEmpty ? L10n.Caption.whisperLoadingModel : msg,
                value: p
            )

        case .transcribing(let p):
            progressRow(label: L10n.Caption.whisperTranscribing, value: p)

        case .correcting(_, let msg):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button(L10n.Common.cancel) { transcriber.cancel() }
                    .controlSize(.mini)
            }

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Button(L10n.Common.retry) {
                    transcriber.retranscribeAll(store: store)
                }
                .controlSize(.mini)
            }
        }
    }

    private func progressRow(label: String, value: Double, showCancel: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: value)
                .controlSize(.small)
            if showCancel {
                Button(L10n.Common.cancel) { transcriber.cancel() }
                    .controlSize(.mini)
            }
        }
    }

    // MARK: - Selected region editor

    @ViewBuilder
    private var selectedRegionSection: some View {
        if let region = timeline.selectedCaptionRegion(in: store.project?.editor ?? EditorState()) {
            regionEditor(region: region)
        } else {
            emptySelectionView
        }
    }

    private var emptySelectionView: some View {
        Text(L10n.Caption.regionSelectPrompt)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func regionEditor(region: CaptionRegion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow(region: region)

            fieldLabel(L10n.Caption.regionText)
            // FIX_10 UX-B: draft + FocusState。打鍵中は updateCaption (undo 履歴なし)、
            // blur で commitCaption (undo 1 回分)。
            TextEditor(text: draftBinding(region: region))
                .focused($textFocused)
                .font(.system(size: 13))
                .frame(minHeight: 60, maxHeight: 160)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .onAppear {
                    syncDraft(for: region)
                }
                .onChange(of: region.id) { _ in
                    // 別 region を選択したら draft を同期 (前 region を暗黙 commit してから)。
                    if textFocused { commitDraft(forRegionID: draftRegionID) }
                    syncDraft(for: region)
                }
                .onChange(of: textFocused) { focused in
                    // blur で commit。focus on のときは何もしない (打鍵で updateCaption 発火済み)。
                    if !focused { commitDraft(forRegionID: draftRegionID) }
                }

            // 時刻編集
            HStack(spacing: 8) {
                timeField(label: "開始 (ms)", value: startBinding(region: region))
                timeField(label: "終了 (ms)", value: endBinding(region: region))
            }


            slowLoopButton(region: region)

            HStack(spacing: 8) {
                Button {
                    transcriber.retranscribeRegion(regionID: region.id, store: store)
                } label: {
                    Label(L10n.Caption.regionResynthesize, systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasAudioSource || transcriber.isRunning)

                Spacer()

                Button(role: .destructive) {
                    timeline.delete(regionID: region.id, store: store)
                } label: {
                    Label(L10n.Caption.regionDelete, systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // アンサンブルチェック (別エンジンでこの区間だけ再認識)
            ensembleCheckControls(region: region)
        }
    }

    /// 「別エンジンで確認」セクション。主エンジン以外のエンジンを選んで再認識。
    /// 結果は region.engineResults に保存され、タイムラインのカラムで表示できる。
    @ViewBuilder
    private func ensembleCheckControls(region: CaptionRegion) -> some View {
        let primary = PreferencesStore.shared.sttEngine
        let hasCandidates = STTEngineType.allCases.contains { type in
            type != primary && (type == .parakeet || type == .qwen3)
        }
        if hasCandidates {
            VStack(alignment: .leading, spacing: 6) {
                Divider().padding(.vertical, 2)
                let inFlight = transcriber.ensembleInFlight.contains(region.id)
                Button {
                    transcriber.startCrossCheck(regionID: region.id, store: store)
                } label: {
                    HStack(spacing: 4) {
                        if inFlight {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "wand.and.sparkles")
                                .font(.system(size: 10))
                        }
                        Text(inFlight ? "クロスチェック中…" : "クロスチェック")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(inFlight || !hasAudioSource)
                // 既存結果の表示
                let candidates: [STTEngineType] = STTEngineType.allCases.filter { type in
                    type != primary && (type == .parakeet || type == .qwen3)
                }
                ForEach(candidates) { engineType in
                    if let text = region.engineResults[engineType.rawValue], !text.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engineType.displayName)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(text)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.04))
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func slowLoopButton(region: CaptionRegion) -> some View {
        if playback.isSlowLooping {
            slowLoopControls
        } else {
            HStack(spacing: 8) {
                Button {
                    let startSec = Double(region.startMs) / 1000.0
                    let endSec = Double(region.endMs) / 1000.0
                    playback.startSlowLoop(regionStartSec: startSec, regionEndSec: endSec)
                } label: {
                    Label(L10n.Caption.regionListenLoop, systemImage: "ear")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasAudioSource)

                if playback.totalCachedCount > 0 {
                    Spacer()
                    Button {
                        playback.purgeCache()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                            Text(L10n.Caption.regionClearCache)
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.Caption.regionCacheCount(playback.totalCachedCount))
                }
            }
        }
    }

    private var slowLoopControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "ear")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(L10n.Caption.regionListening)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    playback.stopSlowLoop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("ループ停止")
            }

            HStack(spacing: 8) {
                Button {
                    playback.setLoopSpeed(playback.loopSpeedPercent - 1)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(playback.loopSpeedPercent <= 50)

                Text("\(playback.loopSpeedPercent)%")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        playback.loopSpeedPercent == 100
                            ? EditorTheme.textPrimary
                            : .orange
                    )
                    .frame(width: 48, alignment: .center)

                Button {
                    playback.setLoopSpeed(playback.loopSpeedPercent + 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(playback.loopSpeedPercent >= 100)

                Spacer()

                if playback.isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("\(Int(playback.renderProgress * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(EditorTheme.textTertiary)
                } else if !playback.cachedSpeeds.contains(playback.loopSpeedPercent) {
                    Text(L10n.Caption.regionPreparing)
                        .font(.system(size: 9))
                        .foregroundStyle(EditorTheme.textTertiary)
                }
            }

            Slider(
                value: Binding(
                    get: { Double(playback.loopSpeedPercent) },
                    set: { playback.setLoopSpeed(Int($0)) }
                ),
                in: 50...100,
                step: 1
            )
            .controlSize(.mini)
            .tint(.orange)

            HStack {
                Text("50%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(EditorTheme.textTertiary)
                Spacer()
                Text("100%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(EditorTheme.textTertiary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func statusRow(region: CaptionRegion) -> some View {
        HStack(spacing: 6) {
            if transcriber.retranscribeInFlight.contains(region.id)
                || transcriber.ensembleInFlight.contains(region.id)
                || transcriber.correctionInFlight.contains(region.id) {
                ProgressView()
                    .controlSize(.mini)
                Text("処理中…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if region.isManuallyEdited {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.cyan)
                Text(L10n.Caption.regionManuallyEdited).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if region.confidence < 0.6 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(L10n.Caption.regionLowConfidence(region.confidence * 100))
                    .font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L10n.Caption.regionAutoSynthesized(region.confidence * 100))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func timeField(label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            fieldLabel(label)
            TextField("", value: value, formatter: Self.intFormatter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = NSNumber(value: 0)
        f.maximum = NSNumber(value: 24 * 60 * 60 * 1000)
        f.numberStyle = .none
        return f
    }()

    // MARK: - Dictionary learning banner

    @ViewBuilder
    private var dictionaryLearningBanner: some View {
        if let diff = pendingDiff {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 11))
                    Text(L10n.Caption.dictDetected)
                        .font(.system(size: 11, weight: .semibold))
                }

                HStack(spacing: 4) {
                    Text("\"\(diff.before)\"")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .strikethrough()
                    Text(L10n.Common.arrow)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("\"\(diff.after)\"")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }

                if matchingRegionCount > 0 {
                    Text(L10n.Caption.dictOtherMatches(matchingRegionCount))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    if matchingRegionCount > 0 {
                        Button(L10n.Caption.dictFixAll) {
                            registerAndApplyAll(diff: diff)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }

                    Button(L10n.Caption.dictRegisterOnly) {
                        registerOnly(diff: diff)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button(L10n.Caption.dictIgnore) {
                        pendingDiff = nil
                    }
                    .controlSize(.mini)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.yellow.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.yellow.opacity(0.3), lineWidth: 0.5)
                    )
            )
        }
    }

    private func registerAndApplyAll(diff: EditDiff) {
        let entry = DictionaryEntry(
            wrong: diff.before,
            correct: diff.after,
            source: .autoLearned
        )
        dictionaryStore.addEntry(entry)

        // 全 region から同じパターンを一括置換
        guard var state = store.project?.editor else { return }
        let matching = DictionaryCorrector.findRegionsContaining(
            wrong: diff.before,
            in: state.captionRegions
        )
        for region in matching {
            if let idx = state.captionRegions.firstIndex(where: { $0.id == region.id }) {
                state.captionRegions[idx] = DictionaryCorrector.applySingle(
                    entry: entry,
                    to: region
                )
            }
        }
        store.commitState(state)
        pendingDiff = nil
    }

    private func registerOnly(diff: EditDiff) {
        let entry = DictionaryEntry(
            wrong: diff.before,
            correct: diff.after,
            source: .autoLearned
        )
        dictionaryStore.addEntry(entry)
        pendingDiff = nil
    }

    // MARK: - Supported Languages

    private struct SupportedLanguage {
        let code: String
        let label: String
    }

    private static let supportedLanguages: [SupportedLanguage] = [
        .init(code: "ja", label: "日本語"),
        .init(code: "en", label: "English"),
        .init(code: "fr", label: "Français"),
        .init(code: "de", label: "Deutsch"),
        .init(code: "it", label: "Italiano"),
        .init(code: "es", label: "Español"),
        .init(code: "auto", label: "自動検出"),
    ]

    // MARK: - Bindings

    private var settings: CaptionSettings {
        store.project?.editor.captionSettings ?? .default
    }

    private func additionalLanguageBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { settings.additionalLanguages.contains(code) },
            set: { enabled in
                guard var state = store.project?.editor else { return }
                if enabled {
                    if !state.captionSettings.additionalLanguages.contains(code) {
                        state.captionSettings.additionalLanguages.append(code)
                    }
                } else {
                    state.captionSettings.additionalLanguages.removeAll { $0 == code }
                }
                store.commitState(state)
                PreferencesStore.shared.saveWhisperSettings(state.captionSettings)
            }
        )
    }

    /// 非 Whisper エンジンで .none が選ばれていたら .energy にフォールバックする Binding
    private var vadMethodBinding: Binding<VADMethod> {
        Binding(
            get: {
                let current = settings.vadMethod
                if current == .none && !PreferencesStore.shared.sttEngine.supportsNoVAD {
                    return .energy
                }
                return current
            },
            set: { newValue in
                guard var state = store.project?.editor else { return }
                state.captionSettings.vadMethod = newValue
                store.commitState(state)
                PreferencesStore.shared.saveWhisperSettings(state.captionSettings)
            }
        )
    }

    private func bindingSettings<V>(keyPath: WritableKeyPath<CaptionSettings, V>) -> Binding<V> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                guard var state = store.project?.editor else { return }
                state.captionSettings[keyPath: keyPath] = newValue
                store.commitState(state)
                PreferencesStore.shared.saveWhisperSettings(state.captionSettings)
            }
        )
    }

    /// draft を直接バインドする Binding。set 時に draft 更新 + 即時反映 (updateCaption)。
    /// commit は blur 時 (onChange of textFocused) にまとめて呼ぶので、ここでは呼ばない。
    private func draftBinding(region: CaptionRegion) -> Binding<String> {
        Binding(
            get: { draft },
            set: { newValue in
                draft = newValue
                draftRegionID = region.id
                var r = currentRegion(fallback: region)
                r.text = newValue
                r.isManuallyEdited = true
                r.confidence = 1.0
                timeline.updateCaption(r, store: store)
            }
        )
    }

    /// 選択 region が切り替わったときに draft を region の最新テキストに揃える。
    private func syncDraft(for region: CaptionRegion) {
        draft = currentRegion(fallback: region).text
        draftRegionID = region.id
    }

    /// blur / region 切替時に draft を undo 履歴込みで確定する。
    private func commitDraft(forRegionID id: UUID?) {
        guard let id,
              var state = store.project?.editor,
              let idx = state.captionRegions.firstIndex(where: { $0.id == id }) else { return }
        var r = state.captionRegions[idx]
        let beforeText = r.text
        r.text = draft
        r.isManuallyEdited = true
        r.confidence = 1.0
        state.captionRegions[idx] = r
        store.commitState(state)

        // 自動辞書学習: 編集前後の diff から辞書登録候補を検出
        checkDictionaryLearning(before: beforeText, after: draft, regionID: id)
    }

    /// 編集 diff を抽出し、辞書未登録かつ他の region にも同じ誤認識があれば提案。
    private func checkDictionaryLearning(before: String, after: String, regionID: UUID) {
        guard let diff = EditDiffExtractor.extract(before: before, after: after) else { return }
        guard !dictionaryStore.hasEntry(wrong: diff.before) else { return }

        let regions = store.project?.editor.captionRegions ?? []
        let matching = DictionaryCorrector.findRegionsContaining(
            wrong: diff.before,
            in: regions,
            excludingRegionID: regionID
        )
        matchingRegionCount = matching.count
        pendingDiff = diff
    }

    private func startBinding(region: CaptionRegion) -> Binding<Int> {
        Binding(
            get: { currentRegion(fallback: region).startMs },
            set: { newValue in
                var r = currentRegion(fallback: region)
                r.startMs = max(0, min(newValue, r.endMs - 100))
                r.isManuallyEdited = true
                timeline.commitCaption(r, store: store)
            }
        )
    }

    private func endBinding(region: CaptionRegion) -> Binding<Int> {
        Binding(
            get: { currentRegion(fallback: region).endMs },
            set: { newValue in
                var r = currentRegion(fallback: region)
                r.endMs = max(r.startMs + 100, newValue)
                r.isManuallyEdited = true
                timeline.commitCaption(r, store: store)
            }
        )
    }

    private func currentRegion(fallback: CaptionRegion) -> CaptionRegion {
        store.project?.editor.captionRegions.first { $0.id == fallback.id } ?? fallback
    }


    private var hasAudioSource: Bool {
        guard let media = store.project?.media else { return false }
        return !media.screenVideoPath.isEmpty
            && FileManager.default.fileExists(atPath: media.screenVideoPath)
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
