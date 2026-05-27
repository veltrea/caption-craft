import AVFoundation
import AudioCommon
import Combine
import Foundation
import NaturalLanguage

// MARK: - CaptionTranscriber

/// Caption トラックの文字起こしパイプラインを駆動するオーケストレータ。
/// `CaptionEngine` を注入して Whisper 実装と分離。
///
/// 成熟度: experimental (FIX_10 Phase 1)
///
/// 責務:
/// - 録画映像 (MediaPaths.screenVideoPath) の URL 解決
/// - CaptionEngine.prepare → transcribe を呼び出し、進捗を @Published に流す
/// - 結果を CaptionSegmenter に渡して再分割
/// - 既存 captionRegions のうち isManuallyEdited な region を保護した上で置き換える
/// - キャンセル / 同時実行抑止
@MainActor
final class CaptionTranscriber: ObservableObject {

    @Published private(set) var status: CaptionRenderStatus = .idle
    @Published private(set) var isRunning: Bool = false

    /// 音声エンジン。
    var engine: CaptionEngine

    /// 校正辞書ストア。書き起こし後の辞書ベース置換に使用。
    var dictionaryStore: DictionaryStore?

    /// LLM 校正サービス。書き起こし後に文脈推定 + 一括校正を自動実行する。
    var correctionService: CorrectionService?

    /// LLM エンドポイント URL。TranslationService と共有する設定。
    var llmEndpoint: URL = URL(string: "http://localhost:1234")!

    private var currentTask: Task<Void, Never>?

    /// アンサンブルチェック用の副エンジンインスタンスを保持する。
    /// オンデマンド起動で初回 lazy load。主エンジンとは独立に存在する。
    private var secondaryEngines: [STTEngineType: CaptionEngine] = [:]

    /// 発話区間検出 (VAD)。新パイプラインで使う。
    private let vad = VoiceActivityDetector()

    /// パイプライン実行中のエラー集約。パイプライン開始時に生成、終了時にレポート。
    /// nonisolated(unsafe): ASR Task (non-MainActor) からも直接アクセスする。
    /// PipelineHealthTracker 内部で NSLock により排他制御済み。
    nonisolated(unsafe) var healthTracker: PipelineHealthTracker?

    /// VAD + ASR 並行パイプラインの進捗状態。
    /// MainActor で更新・読み取りされる。
    @MainActor
    final class PipelineProgressBox {
        var vadProgress: Double = 0      // 0.0–1.0
        var vadDetectedCount: Int = 0    // VAD が累積で検出した区間数
        var asrDone: Int = 0             // ASR が完了した区間数
    }

    /// アンサンブルチェック中のリージョン (UI で進捗表示するため)。
    @Published private(set) var ensembleInFlight: Set<UUID> = []

    /// 再書き起こし中のリージョン (UI でスピナー表示するため)。
    @Published private(set) var retranscribeInFlight: Set<UUID> = []

    /// LLM 校正中のリージョン (UI でスピナー表示するため)。
    @Published var correctionInFlight: Set<UUID> = []

    /// 現在モーダル表示中のアンサンブルチェックセッション。
    /// VideoEditorView の .sheet(item:) でこれを観測してモーダルを開閉する。
    @Published var activeEnsembleSession: EnsembleCheckSession?

    init(engine: CaptionEngine = MockCaptionEngine()) {
        self.engine = engine
    }

    deinit {
        currentTask?.cancel()
    }

    // MARK: - Entry points

    /// トラック全体を (再) 合成する。
    /// 既存の isManuallyEdited 済み region は保護され、それ以外が新結果で置き換えられる。
    func retranscribeAll(store: ProjectStore) {
        guard let state = store.project?.editor else { return }
        guard let audioURL = resolveAudioURL(store: store) else {
            status = .failed("録画ファイルが見つかりません")
            return
        }
        start(store: store, settings: state.captionSettings, audioURL: audioURL)
    }

    /// 1 region のみ再合成する (選択中 region の範囲だけ Whisper を流し直す)。
    func retranscribeRegion(regionID: UUID, store: ProjectStore) {
        guard var state = store.project?.editor,
              let idx = state.captionRegions.firstIndex(where: { $0.id == regionID }) else { return }
        state.captionRegions[idx].isManuallyEdited = false
        store.updateState(state)
        retranscribeAll(store: store)
    }

    /// 指定リージョンを指定言語で再書き起こしする (faster-whisper 使用)。
    /// 翻訳ではなく、「この区間はフランス語で話されている」と言語を指定して
    /// 原語のまま書き起こし直す。言語学習者向けのオンデマンド機能。
    func retranscribeWithLanguage(regionID: UUID, language: String, store: ProjectStore) {
        guard let state = store.project?.editor,
              let region = state.captionRegions.first(where: { $0.id == regionID }),
              let audioURL = resolveAudioURL(store: store) else {
            return
        }

        let fwEngine = FasterWhisperCaptionEngine()
        retranscribeInFlight.insert(regionID)

        let startMs = region.startMs
        let endMs = region.endMs
        let splitEnabled = store.project?.editor.captionSettings.splitLongRegions ?? true
        let maxWords = store.project?.editor.captionSettings.maxWordsPerSegment ?? 10

        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.retranscribeInFlight.remove(regionID)
                }
            }
            do {
                let samples = try AudioFileLoader.load(url: audioURL, targetSampleRate: 16_000)
                let startSample = max(0, startMs * 16_000 / 1000)
                let endSample = min(samples.count, endMs * 16_000 / 1000)
                guard startSample < endSample else { return }

                let chunk = Array(samples[startSample..<endSample])

                let text = try await fwEngine.transcribeSamples(
                    samples: chunk,
                    sampleRate: 16_000,
                    language: language
                )

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                let resultRegion = CaptionRegion(
                    startMs: startMs,
                    endMs: endMs,
                    text: trimmed,
                    isManuallyEdited: false,
                    sourceLanguage: language,
                    confidence: 1.0
                )
                let splitRegions: [CaptionRegion]
                if splitEnabled {
                    splitRegions = CaptionSegmenter.splitLongRegions(
                        [resultRegion],
                        maxDurationMs: 8000,
                        maxWords: maxWords
                    )
                } else {
                    splitRegions = [resultRegion]
                }

                await MainActor.run {
                    guard var state = store.project?.editor,
                          let idx = state.captionRegions.firstIndex(where: { $0.id == regionID }) else { return }
                    state.captionRegions.replaceSubrange(idx...idx, with: splitRegions)
                    store.commitState(state)
                    AppLog.transcribe.info("言語変更再書き起こし完了: [\(startMs)-\(endMs)] lang=\(language, privacy: .public) → \(splitRegions.count) regions")
                }
            } catch {
                AppLog.transcribe.error("言語変更再書き起こし失敗: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self?.status = .failed("再書き起こし失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 複数リージョンをまとめて指定言語で再書き起こしする。
    /// 時間範囲指定で一括処理するための API。各リージョンを順番に処理する。
    func retranscribeRangeWithLanguage(regionIDs: [UUID], language: String, store: ProjectStore) {
        guard let audioURL = resolveAudioURL(store: store) else { return }

        let fwEngine = FasterWhisperCaptionEngine()

        Task { [weak self] in
            do {
                let samples = try AudioFileLoader.load(url: audioURL, targetSampleRate: 16_000)

                var successCount = 0
                var failCount = 0
                for (i, regionID) in regionIDs.enumerated() {
                    try Task.checkCancellation()
                    guard let state = store.project?.editor,
                          let region = state.captionRegions.first(where: { $0.id == regionID }) else { continue }

                    let startSample = max(0, region.startMs * 16_000 / 1000)
                    let endSample = min(samples.count, region.endMs * 16_000 / 1000)
                    guard startSample < endSample else { continue }

                    let chunk = Array(samples[startSample..<endSample])
                    // 短すぎる区間（250ms未満）はスキップ
                    if chunk.count < 4000 { continue }

                    do {
                        let text = try await fwEngine.transcribeSamples(
                            samples: chunk,
                            sampleRate: 16_000,
                            language: language
                        )
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

                        let resultRegion = CaptionRegion(
                            startMs: region.startMs,
                            endMs: region.endMs,
                            text: trimmed,
                            isManuallyEdited: false,
                            sourceLanguage: language,
                            confidence: trimmed.isEmpty ? 0 : 1.0
                        )
                        let batchSplitEnabled = store.project?.editor.captionSettings.splitLongRegions ?? true
                        let splitRegions: [CaptionRegion]
                        if batchSplitEnabled {
                            splitRegions = CaptionSegmenter.splitLongRegions(
                                [resultRegion],
                                maxDurationMs: 8000,
                                maxWords: store.project?.editor.captionSettings.maxWordsPerSegment ?? 10
                            )
                        } else {
                            splitRegions = [resultRegion]
                        }

                        await MainActor.run {
                            guard var state = store.project?.editor,
                                  let idx = state.captionRegions.firstIndex(where: { $0.id == regionID }) else { return }
                            state.captionRegions.replaceSubrange(idx...idx, with: splitRegions)
                            store.commitState(state)
                        }
                        successCount += 1
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failCount += 1
                        AppLog.transcribe.error("一括再書き起こし [\(region.startMs)-\(region.endMs)] 失敗 (続行): \(error.localizedDescription, privacy: .public)")
                    }

                    await MainActor.run { [weak self] in
                        self?.status = .transcribing(progress: Double(i + 1) / Double(regionIDs.count))
                    }
                }
                AppLog.transcribe.info("一括再書き起こし: 成功 \(successCount) / 失敗 \(failCount)")

                await MainActor.run { [weak self] in
                    self?.status = .idle
                }
                AppLog.transcribe.info("範囲一括再書き起こし完了: \(regionIDs.count) regions, lang=\(language, privacy: .public)")
            } catch {
                AppLog.transcribe.error("範囲一括再書き起こし失敗: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { [weak self] in
                    self?.status = .failed("一括再書き起こし失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    /// アンサンブルチェックを開始する。
    /// モーダルセッションを作成して activeEnsembleSession にセットし、
    /// VideoEditorView の .sheet で観測されることで自動的にモーダルが開く。
    /// クロスチェックを開始する。全副エンジンを逐次実行する。
    func startCrossCheck(regionID: UUID, store: ProjectStore) {
        guard let state = store.project?.editor,
              let region = state.captionRegions.first(where: { $0.id == regionID }) else {
            AppLog.transcribe.error("startCrossCheck: region \(regionID, privacy: .public) が見つかりません")
            return
        }
        guard resolveAudioURL(store: store) != nil else {
            AppLog.transcribe.error("startCrossCheck: 音声ファイルが見つかりません")
            return
        }
        guard activeEnsembleSession == nil else {
            AppLog.transcribe.info("startCrossCheck: 既にセッションが開いています")
            return
        }

        let primary = PreferencesStore.shared.sttEngine
        let primaryVariant = PreferencesStore.shared.whisperModelVariant
        // 副エンジン: Parakeet + Qwen3 は常に含める。
        // Whisper Large v3 は主エンジンが Whisper large-v3 でない場合のみ含める
        // （同一モデルの重複チェックを避けるため）。
        var secondaries: [STTEngineType] = []
        if primary != .whisper || primaryVariant != .largev3 {
            secondaries.append(.whisper)
        }
        secondaries.append(contentsOf: [.parakeet, .qwen3].filter { $0 != primary })
        guard !secondaries.isEmpty else { return }

        let session = EnsembleCheckSession(
            region: region,
            primary: primary,
            secondaries: secondaries
        )
        activeEnsembleSession = session
        executeCrossCheck(store: store)
    }

    /// 全副エンジンを逐次実行する（並列しない: GPU/ANE 競合回避）。
    private func executeCrossCheck(store: ProjectStore) {
        guard let session = activeEnsembleSession else { return }
        guard let state = store.project?.editor,
              let region = state.captionRegions.first(where: { $0.id == session.regionID }) else { return }
        guard let audioURL = resolveAudioURL(store: store) else { return }

        let regionID = session.regionID
        let startMs = region.startMs
        let endMs = region.endMs

        ensembleInFlight.insert(regionID)

        Task { [weak self, weak session] in
            defer {
                Task { @MainActor [weak self] in
                    self?.ensembleInFlight.remove(regionID)
                }
            }

            guard let session else { return }
            let lang = await MainActor.run { session.language }
            let engines = await MainActor.run { session.secondaryEngines }

            for engineType in engines {
                do {
                    await MainActor.run { session.setPhase(.preparing, for: engineType) }

                    let text = try await self?.runEnsembleEngine(
                        engineType: engineType,
                        audioURL: audioURL,
                        startMs: startMs,
                        endMs: endMs,
                        language: lang
                    ) ?? ""
                    try Task.checkCancellation()

                    await MainActor.run {
                        session.applyResult(for: engineType, text: text)
                        self?.commitEnsembleResult(
                            regionID: regionID,
                            engineKey: engineType.rawValue,
                            text: text,
                            store: store
                        )
                    }
                    AppLog.transcribe.info("crossCheck 完了: region=\(regionID, privacy: .public) engine=\(engineType.rawValue, privacy: .public)")
                } catch is CancellationError {
                    AppLog.transcribe.notice("crossCheck キャンセル: \(regionID, privacy: .public)")
                    await MainActor.run { session.markFailed(for: engineType, message: "キャンセル") }
                    break
                } catch {
                    AppLog.transcribe.error("crossCheck 失敗 engine=\(engineType.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    await MainActor.run { session.markFailed(for: engineType, message: error.localizedDescription) }
                }
            }
        }
    }

    /// セッションを閉じる。
    func dismissEnsembleSession() {
        activeEnsembleSession = nil
    }

    /// クロスチェック画面で編集されたテキストを字幕に反映する。
    func updateCrossCheckText(_ text: String, store: ProjectStore) {
        guard let session = activeEnsembleSession,
              var state = store.project?.editor,
              let idx = state.captionRegions.firstIndex(where: { $0.id == session.regionID }) else { return }
        state.captionRegions[idx].text = text
        state.captionRegions[idx].isManuallyEdited = true
        store.commitState(state)
        activeEnsembleSession = nil
    }

    /// 副エンジンインスタンスを取得 (初回は lazy 生成)。
    /// クロスチェック用の Whisper は常に Large v3 固定（最高精度で再解析するため）。
    private func ensureSecondaryEngine(_ type: STTEngineType) -> CaptionEngine {
        if let existing = secondaryEngines[type] {
            return existing
        }
        let engine: CaptionEngine
        switch type {
        case .whisper:    engine = WhisperKitCaptionEngine(modelVariant: .largev3)
        case .parakeet:   engine = ParakeetCaptionEngine()
        case .qwen3:      engine = Qwen3CaptionEngine()
        case .fasterWhisper: engine = FasterWhisperCaptionEngine()
        }
        secondaryEngines[type] = engine
        return engine
    }

    /// 副エンジン実行のコア。指定範囲の音声を抽出してエンジンに渡す。
    nonisolated private func runEnsembleEngine(
        engineType: STTEngineType,
        audioURL: URL,
        startMs: Int,
        endMs: Int,
        language: String = ""
    ) async throws -> String {
        // 音声の該当範囲を 16kHz Float32 で抽出
        let samples = try await Self.extractAudioSlice(
            url: audioURL,
            startMs: startMs,
            endMs: endMs,
            targetSampleRate: 16_000
        )
        AppLog.transcribe.info("ensembleCheck: \(samples.count) samples extracted (engine=\(engineType.rawValue, privacy: .public))")

        // 副エンジンを取得 (未準備なら prepare する)
        let secondary = await MainActor.run { self.ensureSecondaryEngine(engineType) }
        try await secondary.prepare { _ in }
        return try await secondary.transcribeSamples(
            samples: samples,
            sampleRate: 16_000,
            language: language
        )
    }

    /// アンサンブル結果を該当 region の engineResults に格納してコミット。
    private func commitEnsembleResult(
        regionID: UUID,
        engineKey: String,
        text: String,
        store: ProjectStore
    ) {
        guard var state = store.project?.editor,
              let idx = state.captionRegions.firstIndex(where: { $0.id == regionID }) else {
            return
        }
        state.captionRegions[idx].engineResults[engineKey] = text
        store.commitState(state)
    }

    /// 実行中タスクをキャンセルする。
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        status = .idle
    }

    // MARK: - Core pipeline

    private func start(
        store: ProjectStore,
        settings: CaptionSettings,
        audioURL: URL
    ) {
        let languages = settings.allLanguages
        NSLog("[Pipeline] 開始: lang=%@ multilingual=%d audio=%@", languages.joined(separator: ","), settings.isMultilingual ? 1 : 0, audioURL.lastPathComponent)
        ACPLogStore.shared.append(category: "pipeline", level: "info", message: "パイプライン開始: lang=\(languages.joined(separator: ",")) audio=\(audioURL.lastPathComponent)")
        Self.logMemoryState(context: "パイプライン開始")
        currentTask?.cancel()
        isRunning = true
        status = .loadingModel(progress: 0)

        let tracker = PipelineHealthTracker()
        self.healthTracker = tracker
        let engine = self.engine
        currentTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.isRunning = false
                    self?.currentTask = nil
                }
            }
            do {
                let newRegions: [CaptionRegion]
                if settings.isMultilingual {
                    newRegions = try await self?.transcribeMultilingual(
                        engine: engine,
                        audioURL: audioURL,
                        settings: settings,
                        store: store
                    ) ?? []
                } else {
                    newRegions = try await self?.transcribeWithVAD(
                        engine: engine,
                        audioURL: audioURL,
                        settings: settings,
                        store: store
                    ) ?? []
                }
                try Task.checkCancellation()

                AppLog.transcribe.info("VAD パイプライン完了: \(newRegions.count) regions")
                ACPLogStore.shared.append(category: "pipeline", level: "info", message: "VAD完了: \(newRegions.count) regions")

                await MainActor.run {
                    self?.mergeAndCommit(newRegions: newRegions, store: store)
                }

                // 辞書ベース校正 (自動)
                let correctedRegions: [CaptionRegion]
                if settings.autoCorrectWithDictionary,
                   let dictStore = self?.dictionaryStore,
                   !dictStore.dictionary.entries.isEmpty {
                    await MainActor.run {
                        self?.status = .correcting(phase: .dictionary, progress: "辞書適用中…")
                    }
                    let (regions, appliedIDs) = DictionaryCorrector.apply(
                        dictionary: dictStore.dictionary,
                        to: newRegions
                    )
                    correctedRegions = regions
                    for entryID in appliedIDs {
                        dictStore.incrementUseCount(id: entryID)
                    }
                    await MainActor.run {
                        self?.mergeAndCommit(newRegions: correctedRegions, store: store)
                    }
                    AppLog.transcribe.info("辞書校正完了: \(appliedIDs.count) entries 適用")
                    ACPLogStore.shared.append(category: "pipeline", level: "info", message: "辞書校正完了: \(appliedIDs.count) entries 適用")
                } else {
                    correctedRegions = newRegions
                }
                try Task.checkCancellation()

                // LLM 校正 (自動、設定でオン時のみ)
                // 多言語モード: 言語ごとにグループ分けし、言語に応じたプロンプトで校正する。
                let llmCorrectedRegions: [CaptionRegion]
                if settings.autoCorrectWithLLM,
                   let corrService = self?.correctionService,
                   let endpoint = self?.llmEndpoint {
                    await MainActor.run {
                        self?.status = .correcting(phase: .analyzing, progress: "文脈推定中…")
                    }
                    let client = LLMClient(endpoint: endpoint)
                    let hints = settings.domainHints

                    do {
                        if settings.isMultilingual {
                            // 言語ごとにグループ分けして校正
                            var langGroups: [String: [CaptionRegion]] = [:]
                            for r in correctedRegions {
                                langGroups[r.sourceLanguage, default: []].append(r)
                            }
                            var allCorrected: [CaptionRegion] = []
                            for (lang, group) in langGroups {
                                let langName = CaptionTranscriber.languageDisplayName(lang)
                                await MainActor.run { [weak self] in
                                    self?.status = .correcting(phase: .correcting, progress: "\(langName) を校正中… (\(group.count) 件)")
                                }
                                AppLog.transcribe.info("多言語 LLM 校正: \(langName) \(group.count) 件")
                                let result = try await corrService.correct(
                                    regions: group,
                                    domainHints: hints,
                                    client: client,
                                    language: langName
                                ) { partial in
                                    Task { @MainActor in
                                        let merged = (allCorrected + partial).sorted { $0.startMs < $1.startMs }
                                        self?.mergeAndCommit(newRegions: merged, store: store)
                                    }
                                }
                                allCorrected.append(contentsOf: result)
                            }
                            llmCorrectedRegions = allCorrected.sorted { $0.startMs < $1.startMs }
                        } else {
                            let totalRegions = correctedRegions.count
                            llmCorrectedRegions = try await corrService.correct(
                                regions: correctedRegions,
                                domainHints: hints,
                                client: client,
                                language: "日本語"
                            ) { partial in
                                Task { @MainActor in
                                    self?.mergeAndCommit(newRegions: partial, store: store)
                                    if let svcProgress = self?.correctionService?.progress, !svcProgress.isEmpty {
                                        self?.status = .correcting(phase: .correcting, progress: svcProgress)
                                    } else {
                                        self?.status = .correcting(
                                            phase: .correcting,
                                            progress: "校正中… (\(totalRegions) 件)"
                                        )
                                    }
                                }
                            }
                        }
                        AppLog.transcribe.info("LLM 校正完了")
                        ACPLogStore.shared.append(category: "pipeline", level: "info", message: "LLM校正完了")
                    } catch {
                        AppLog.transcribe.error("LLM 校正失敗 (続行): \(error.localizedDescription, privacy: .public)")
                        ACPLogStore.shared.append(category: "pipeline", level: "error", message: "LLM校正失敗: \(error.localizedDescription)")
                        llmCorrectedRegions = correctedRegions
                    }
                } else {
                    llmCorrectedRegions = correctedRegions
                }

                // 長すぎるリージョンをポスト分割（オプション）
                let finalRegions: [CaptionRegion]
                if settings.splitLongRegions {
                    finalRegions = CaptionSegmenter.splitLongRegions(
                        llmCorrectedRegions,
                        maxDurationMs: 8000,
                        maxWords: settings.maxWordsPerSegment
                    )
                    if finalRegions.count != llmCorrectedRegions.count {
                        AppLog.transcribe.info("ポスト分割: \(llmCorrectedRegions.count) → \(finalRegions.count) regions")
                    }
                } else {
                    finalRegions = llmCorrectedRegions
                }

                // 最終結果を store に反映
                await MainActor.run {
                    self?.mergeAndCommit(newRegions: finalRegions, store: store)
                }

                // 空リージョン診断: purge 前に実態を調査する
                let preCleanRegions = await MainActor.run {
                    store.project?.editor.captionRegions ?? []
                }
                var diagLangs = Set(["ja", "en", "fr"])
                for l in settings.allLanguages { diagLangs.insert(l) }
                let diagnoses = await PipelineDiagnostics.diagnoseEmptyRegions(
                    regions: preCleanRegions,
                    audioURL: audioURL,
                    engine: engine,
                    testLanguages: Array(diagLangs).sorted()
                )
                _ = diagnoses // レポートは diagnoseEmptyRegions 内で書き出し済み

                // ASR で空のまま残ったリージョンを除去
                await MainActor.run {
                    self?.purgeEmptyRegions(in: store)
                    self?.status = .idle
                }

                // 最終チェック: 全 region をスキャンして空を検出
                let committedRegions = await MainActor.run {
                    store.project?.editor.captionRegions ?? []
                }
                self?.healthTracker?.finalReport(regions: committedRegions)
                AppLog.transcribe.info("パイプライン正常終了")
                ACPLogStore.shared.append(category: "pipeline", level: "info", message: "パイプライン正常終了")
            } catch is CancellationError {
                AppLog.transcribe.notice("パイプラインキャンセル")
                ACPLogStore.shared.append(category: "pipeline", level: "warn", message: "パイプラインキャンセル")
                await MainActor.run { self?.status = .idle }
            } catch {
                AppLog.transcribe.error("パイプライン失敗: \(error.localizedDescription, privacy: .public)")
                ACPLogStore.shared.append(category: "pipeline", level: "error", message: "パイプライン失敗: \(error.localizedDescription)")
                await MainActor.run { self?.status = .failed("\(error.localizedDescription)") }
            }
        }
    }

    // MARK: - VAD ベースのパイプライン (主経路)

    /// VAD で発話区間を検出してから、各区間を ASR エンジンに投げる。
    /// 字幕のタイムスタンプは VAD 由来 (実音波形ベース) で確定するため、
    /// ASR の内部タイムスタンプ精度に依存しない。これが 2026 年の SOTA 設計。
    private func transcribeWithVAD(
        engine: CaptionEngine,
        audioURL: URL,
        settings: CaptionSettings,
        store: ProjectStore
    ) async throws -> [CaptionRegion] {
        let useEnergyVAD = settings.vadMethod == .energy
        let useNoVAD = settings.vadMethod == .none

        // Step 1: 音声ロード (16kHz mono Float32)
        // no-VAD モードでは WhisperKit が url から直接読むので samples は不要。
        // 不要なメモリ確保（29分で約112MB）を避けて GPU メモリ圧迫を防ぐ。
        let samples: [Float]
        if useNoVAD {
            samples = []
            AppLog.transcribe.info("VAD バイパス: samples ロードをスキップ")
        } else {
            await MainActor.run { [weak self] in
                self?.status = .loadingModel(progress: 0, message: "音声を読み込み中…")
            }
            AppLog.transcribe.info("音声ロード開始")
            do {
                samples = try await Task.detached(priority: .userInitiated) { () -> [Float] in
                    try AudioFileLoader.load(url: audioURL, targetSampleRate: 16_000)
                }.value
            } catch {
                throw CaptionEngineError.audioLoadFailed("\(error.localizedDescription)")
            }
            try Task.checkCancellation()
            let totalSec = Double(samples.count) / 16000.0
            NSLog("[Pipeline] 音声ロード完了: %d samples (%.1fs)", samples.count, totalSec)
            ACPLogStore.shared.append(category: "pipeline", level: "info", message: "音声ロード完了: \(String(format: "%.1f", totalSec))s audio")
            Self.logMemoryState(context: "音声ロード後")
        }
        let phase2Start = Date()

        // Step 2: モデル準備
        // EnergyVAD / none: CPU のみなので VAD 側の prepare 不要。ASR だけ準備。
        // SileroVAD: モデルファイル読み込みのみ並行。推論は直列。
        if useEnergyVAD || useNoVAD {
            await MainActor.run { [weak self] in
                self?.status = .loadingModel(progress: 0.1, message: "音声認識モデルを準備中…")
            }
            try await engine.prepare { [weak self] p in
                self?.status = .loadingModel(
                    progress: 0.1 + p * 0.2,
                    message: "音声認識モデルを準備中… (\(Int(p * 100))%)"
                )
            }
        } else {
            await MainActor.run { [weak self] in
                self?.status = .loadingModel(progress: 0.1, message: "モデルを準備中… (VAD + 音声認識)")
            }
            async let vadPrep: Void = vad.prepare { p in
                Task { @MainActor [weak self] in
                    self?.status = .loadingModel(
                        progress: 0.1 + p * 0.1,
                        message: "モデルを準備中… (VAD: \(Int(p * 100))%)"
                    )
                }
            }
            async let engPrep: Void = engine.prepare { [weak self] p in
                self?.status = .loadingModel(
                    progress: 0.2 + p * 0.1,
                    message: "モデルを準備中… (音声認識: \(Int(p * 100))%)"
                )
            }
            try await vadPrep
            try await engPrep
        }
        try Task.checkCancellation()
        let prepElapsed = Date().timeIntervalSince(phase2Start)
        ACPLogStore.shared.append(category: "pipeline", level: "info", message: "モデル準備完了: \(String(format: "%.1f", prepElapsed))s (\(useNoVAD ? "VADなし" : useEnergyVAD ? "EnergyVAD" : "SileroVAD"))")

        // Step 3: VAD 検出 + ASR 文字起こし
        // EnergyVAD: CPU のみなので ASR (GPU) と並行実行 OK
        // SileroVAD: GPU を使うので VAD 完了後に ASR を直列実行
        await MainActor.run { [weak self] in
            self?.status = .transcribing(progress: 0)
        }
        let language = settings.language
        let pipelineStart = Date()
        let progressBox = PipelineProgressBox()

        let engineType = PreferencesStore.shared.sttEngine

        if useNoVAD {
            // --- VAD なし: 音声ファイルを丸ごと WhisperKit に渡す ---
            // WhisperKit が内部で 30 秒チャンク管理とメモリ管理を行う。
            // 手動チャンキングだと GPU 状態が蓄積してクラッシュするため、
            // engine.transcribe(url:) に全部任せる。
            AppLog.transcribe.info("VAD バイパス: engine.transcribe(url:) に音声ファイルを直接渡す")

            let allSegments = try await engine.transcribe(
                url: audioURL,
                language: language,
                progress: { [weak self] p in
                    progressBox.vadProgress = p
                    self?.status = .transcribing(progress: p)
                },
                onSegments: { [weak self] cumulative in
                    guard let self else { return }
                    let regions = cumulative.map { seg in
                        SpeechRegion(startMs: seg.startMs, endMs: seg.endMs)
                    }
                    self.reconcileVADOutput(regions, in: store, language: language)
                    for seg in cumulative {
                        self.updateRegionText(
                            in: store,
                            matching: SpeechRegion(startMs: seg.startMs, endMs: seg.endMs),
                            text: seg.text
                        )
                    }
                    progressBox.vadDetectedCount = cumulative.count
                    progressBox.asrDone = cumulative.count
                    if let lastID = store.project?.editor.captionRegions.last?.id {
                        store.scrollToRegionID = lastID
                    }
                }
            )

            // CaptionSegmenter で句読点分割・無音分割・短字幕マージなどの後処理
            let finalRegions = CaptionSegmenter.resegment(raw: allSegments, settings: settings, language: language)
            await MainActor.run { [weak self] in
                self?.mergeAndCommit(newRegions: finalRegions, store: store)
            }
            AppLog.transcribe.info("VAD バイパス完了: \(allSegments.count) セグメント → \(finalRegions.count) リージョン")
        } else {
            // --- VAD あり: EnergyVAD or SileroVAD ---
            let vadSensitivity = settings.vadSensitivity
            let vadCalibration = settings.vadCalibration
            let vadDetect: (
                _ onCumulativeUpdate: @Sendable @escaping ([SpeechRegion]) -> Void,
                _ onRegionFinalized: @Sendable @escaping (SpeechRegion) -> Void,
                _ progress: @Sendable @escaping (Double) -> Void
            ) async throws -> [SpeechRegion]

            if useEnergyVAD {
                vadDetect = { onCumulative, onFinalized, prog in
                    try await self.vad.detectSpeechEnergyOnly(
                        samples: samples,
                        sampleRate: 16_000,
                        sensitivity: vadSensitivity,
                        calibration: vadCalibration,
                        progress: prog,
                        onCumulativeUpdate: onCumulative,
                        onRegionFinalized: onFinalized
                    )
                }
            } else {
                vadDetect = { onCumulative, onFinalized, prog in
                    try await self.vad.detectSpeech(
                        samples: samples,
                        sampleRate: 16_000,
                        sensitivity: vadSensitivity,
                        calibration: vadCalibration,
                        progress: prog,
                        onCumulativeUpdate: onCumulative,
                        onRegionFinalized: onFinalized
                    )
                }
            }

          if useEnergyVAD {
            // --- EnergyVAD: 並行パイプライン (CPU VAD + GPU ASR 同時実行) ---
            let (regionStream, continuation) = AsyncStream<SpeechRegion>.makeStream()

            AppLog.transcribe.info("ASR consumer task 起動 (EnergyVAD 並行モード)")
            let asrTask = Task { [weak self] in
                var processed = 0
                var consecutiveEmpty = 0
                var currentEngine = engine
                for await sr in regionStream {
                    try Task.checkCancellation()
                    processed += 1
                    NSLog("[ASR] receive #%d: [%d-%d]", processed, sr.startMs, sr.endMs)

                    let asrResult = await self?.processOneSpeechRegion(
                        sr,
                        engine: currentEngine,
                        samples: samples,
                        language: language,
                        store: store,
                        minDurationMs: settings.minSegmentMs
                    ) ?? .failed

                    switch asrResult {
                    case .text(let t): self?.healthTracker?.recordASR(empty: t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    case .failed:      self?.healthTracker?.recordASRFailed()
                    case .skipped:     self?.healthTracker?.recordASRSkipped()
                    case .cancelled:   break
                    }

                    let durationMs = sr.endMs - sr.startMs
                    if asrResult.isEffectivelyEmpty && durationMs > 500 {
                        consecutiveEmpty += 1
                        NSLog("[ASR] 空/失敗 #%d [%d-%d] result=%@", consecutiveEmpty, sr.startMs, sr.endMs, "\(asrResult)")
                    } else if case .skipped = asrResult {
                    } else {
                        consecutiveEmpty = 0
                    }

                    if consecutiveEmpty >= 2 {
                        NSLog("[ASR] 連続空/失敗 %d 回検出 — エンジン再初期化", consecutiveEmpty)
                        ACPLogStore.shared.append(category: "asr", level: "warn", message: "連続空/失敗\(consecutiveEmpty)回 — エンジン再初期化開始")
                        let restartStart = Date()
                        let newEngine = Self.makeEngine(for: engineType)
                        do {
                            try await newEngine.prepare { _ in }
                            currentEngine = newEngine
                            await MainActor.run { self?.engine = newEngine }
                            self?.healthTracker?.recordEngineRestart(success: true)
                            let restartElapsed = Date().timeIntervalSince(restartStart)
                            NSLog("[ASR] エンジン再初期化完了")
                            ACPLogStore.shared.append(category: "asr", level: "info", message: "エンジン再初期化完了: \(String(format: "%.1f", restartElapsed))s")
                        } catch {
                            self?.healthTracker?.recordEngineRestart(success: false)
                            NSLog("[ASR] エンジン再初期化失敗: %@", error.localizedDescription)
                            ACPLogStore.shared.append(category: "asr", level: "error", message: "エンジン再初期化失敗: \(error.localizedDescription)")
                        }
                        consecutiveEmpty = 0
                    }

                    await MainActor.run {
                        progressBox.asrDone += 1
                    }
                    await self?.publishPipelineProgress(progressBox: progressBox)
                }
                AppLog.transcribe.info("ASR consumer task 終了: \(processed) 件処理")
            }

            let speechRegions: [SpeechRegion]
            do {
                speechRegions = try await vadDetect(
                    { cumulative in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.reconcileVADOutput(cumulative, in: store, language: language)
                            progressBox.vadDetectedCount = cumulative.count
                            if let lastID = store.project?.editor.captionRegions.last?.id {
                                store.scrollToRegionID = lastID
                            }
                        }
                        Task { [weak self] in
                            await self?.publishPipelineProgress(progressBox: progressBox)
                        }
                    },
                    { sr in continuation.yield(sr) },
                    { p in Task { @MainActor in progressBox.vadProgress = p } }
                )
            } catch {
                continuation.finish()
                asrTask.cancel()
                throw error
            }

            AppLog.transcribe.info("VAD producer 完了: \(speechRegions.count) 区間 → ASR キュー終端送信")
            continuation.finish()

            AppLog.transcribe.info("ASR 完了待ち中…")
            do {
                // 親タスクのキャンセルを asrTask に伝播させる
                try await withTaskCancellationHandler {
                    try await asrTask.value
                } onCancel: {
                    asrTask.cancel()
                }
            } catch is CancellationError {
                AppLog.transcribe.notice("ASR タスクキャンセル")
            }
        } else {
            // --- SileroVAD: 直列パイプライン (GPU 競合を避ける) ---
            AppLog.transcribe.info("SileroVAD 直列モード: VAD を先に全完了させてから ASR 開始")

            let speechRegions: [SpeechRegion]
            do {
                speechRegions = try await vadDetect(
                    { cumulative in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.reconcileVADOutput(cumulative, in: store, language: language)
                            progressBox.vadDetectedCount = cumulative.count
                            if let lastID = store.project?.editor.captionRegions.last?.id {
                                store.scrollToRegionID = lastID
                            }
                        }
                        Task { [weak self] in
                            await self?.publishPipelineProgress(progressBox: progressBox)
                        }
                    },
                    { _ in },
                    { p in Task { @MainActor in progressBox.vadProgress = p } }
                )
            } catch {
                throw error
            }

            AppLog.transcribe.info("SileroVAD 完了: \(speechRegions.count) 区間 → ASR 直列開始")
            vad.unloadModel()
            var consecutiveEmpty = 0
            var currentEngine = engine
            for (i, sr) in speechRegions.enumerated() {
                try Task.checkCancellation()
                NSLog("[ASR] sequential #%d/%d: [%d-%d]", i + 1, speechRegions.count, sr.startMs, sr.endMs)

                let asrResult = await processOneSpeechRegion(
                    sr,
                    engine: currentEngine,
                    samples: samples,
                    language: language,
                    store: store,
                    minDurationMs: settings.minSegmentMs
                )

                switch asrResult {
                case .text(let t): healthTracker?.recordASR(empty: t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .failed:      healthTracker?.recordASRFailed()
                case .skipped:     healthTracker?.recordASRSkipped()
                case .cancelled:   break
                }

                let durationMs = sr.endMs - sr.startMs
                if asrResult.isEffectivelyEmpty && durationMs > 500 {
                    consecutiveEmpty += 1
                    NSLog("[ASR] 空/失敗 #%d [%d-%d] result=%@", consecutiveEmpty, sr.startMs, sr.endMs, "\(asrResult)")
                } else if case .skipped = asrResult {
                } else {
                    consecutiveEmpty = 0
                }

                if consecutiveEmpty >= 2 {
                    NSLog("[ASR] 連続空/失敗 %d 回検出 — エンジン再初期化", consecutiveEmpty)
                    ACPLogStore.shared.append(category: "asr", level: "warn", message: "連続空/失敗\(consecutiveEmpty)回 — エンジン再初期化開始")
                    let restartStart = Date()
                    let newEngine = Self.makeEngine(for: engineType)
                    do {
                        try await newEngine.prepare { _ in }
                        currentEngine = newEngine
                        self.engine = newEngine
                        healthTracker?.recordEngineRestart(success: true)
                        let restartElapsed = Date().timeIntervalSince(restartStart)
                        NSLog("[ASR] エンジン再初期化完了")
                        ACPLogStore.shared.append(category: "asr", level: "info", message: "エンジン再初期化完了: \(String(format: "%.1f", restartElapsed))s")
                    } catch {
                        healthTracker?.recordEngineRestart(success: false)
                        NSLog("[ASR] エンジン再初期化失敗: %@", error.localizedDescription)
                        ACPLogStore.shared.append(category: "asr", level: "error", message: "エンジン再初期化失敗: \(error.localizedDescription)")
                    }
                    consecutiveEmpty = 0
                }

                await MainActor.run {
                    progressBox.asrDone += 1
                }
                await publishPipelineProgress(progressBox: progressBox)
            }
            AppLog.transcribe.info("ASR 直列処理完了: \(speechRegions.count) 件処理")
        }
        } // end VAD あり

        let elapsed = Date().timeIntervalSince(pipelineStart)
        let pipelineLabel = useNoVAD ? "VADなし直列" : useEnergyVAD ? "EnergyVAD並行" : "SileroVAD直列"
        NSLog("[Pipeline] VAD+ASR 完了 (%.1fs) [%@]", elapsed, pipelineLabel)
        ACPLogStore.shared.append(category: "pipeline", level: "info", message: "VAD+ASR完了: \(String(format: "%.1f", elapsed))s (\(pipelineLabel))")
        Self.logMemoryState(context: "パイプライン完了")

        // 最終 region 列を store から取得して返す
        return await MainActor.run { store.project?.editor.captionRegions ?? [] }
    }

    // MARK: - 多言語パイプライン (言語検出先行型)

    /// 多言語モードのパイプライン。
    /// 設計原則: **言語を先に検出し、検出結果を指定して ASR を実行する**。
    /// これにより Whisper が外国語音声を主言語に「翻訳」してしまう問題を根本的に防ぐ。
    ///
    /// フロー:
    /// 1. 音声ロード + VAD + ASR エンジン準備
    /// 2. VAD で発話区間を検出 (ASR は走らせない)
    /// 3. 各発話区間の音声チャンクに対して detectLanguage → 言語タグ付け
    /// 4. 言語ごとにグループ化し、各区間を検出言語で transcribeSamples
    /// 5. CaptionRegion 列を構築して store に commit
    private func transcribeMultilingual(
        engine: CaptionEngine,
        audioURL: URL,
        settings: CaptionSettings,
        store: ProjectStore
    ) async throws -> [CaptionRegion] {
        var effectiveSettings = settings

        // "auto" は多言語モードでは使えない (Whisper が英語にデフォルトするため)。
        // 追加言語の最初にフォールバックする。
        if effectiveSettings.language == "auto" && !effectiveSettings.additionalLanguages.isEmpty {
            effectiveSettings.language = effectiveSettings.additionalLanguages.first!
            effectiveSettings.additionalLanguages = Array(effectiveSettings.additionalLanguages.dropFirst())
            AppLog.transcribe.info("多言語モード: auto → \(effectiveSettings.language, privacy: .public) にフォールバック")
        }

        let primaryLang = effectiveSettings.language
        let candidateLanguages = effectiveSettings.allLanguages
        AppLog.transcribe.info("多言語パイプライン開始 (言語検出先行型): primary=\(primaryLang, privacy: .public) candidates=\(candidateLanguages.joined(separator: ","), privacy: .public)")

        // --- Phase 1: 音声ロード + VAD + ASR エンジン準備 ---
        await MainActor.run { [weak self] in
            self?.status = .loadingModel(progress: 0, message: "[1/4] 音声を読み込み中…")
        }

        let samples: [Float]
        do {
            samples = try await Task.detached(priority: .userInitiated) { () -> [Float] in
                try AudioFileLoader.load(url: audioURL, targetSampleRate: 16_000)
            }.value
        } catch {
            throw CaptionEngineError.audioLoadFailed("\(error.localizedDescription)")
        }
        try Task.checkCancellation()
        let totalSec = Double(samples.count) / 16000.0
        AppLog.transcribe.info("音声ロード完了: \(samples.count) samples (\(String(format: "%.1f", totalSec))s)")

        // モデル準備: EnergyVAD / none なら ASR のみ、SileroVAD なら VAD + ASR を読み込み
        let useEnergyVAD = effectiveSettings.vadMethod == .energy
        let useNoVAD = effectiveSettings.vadMethod == .none
        if useEnergyVAD || useNoVAD {
            await MainActor.run { [weak self] in
                self?.status = .loadingModel(progress: 0.1, message: "[1/4] ASR モデル準備中…")
            }
            try await engine.prepare { [weak self] p in
                self?.status = .loadingModel(
                    progress: 0.1 + p * 0.2,
                    message: "[1/4] ASR モデル準備中… (\(Int(p * 100))%)"
                )
            }
        } else {
            await MainActor.run { [weak self] in
                self?.status = .loadingModel(progress: 0.1, message: "[1/4] モデルを準備中… (VAD + 音声認識)")
            }
            async let vadPrep: Void = vad.prepare { p in
                Task { @MainActor [weak self] in
                    self?.status = .loadingModel(
                        progress: 0.1 + p * 0.1,
                        message: "[1/4] モデルを準備中… (VAD: \(Int(p * 100))%)"
                    )
                }
            }
            async let engPrep: Void = engine.prepare { [weak self] p in
                self?.status = .loadingModel(
                    progress: 0.2 + p * 0.1,
                    message: "[1/4] モデルを準備中… (音声認識: \(Int(p * 100))%)"
                )
            }
            try await vadPrep
            try await engPrep
        }
        try Task.checkCancellation()

        // --- Phase 2: VAD で発話区間のみ検出 (ASR なし) ---
        await MainActor.run { [weak self] in
            self?.status = .loadingModel(progress: 0.3, message: "[2/4] 発話区間を検出中…")
        }

        let speechRegions: [SpeechRegion]
        if useNoVAD {
            // VAD バイパス: 30 秒チャンクを直接生成
            let totalMs = Int(Double(samples.count) / 16000.0 * 1000.0)
            let chunkMs = 30_000
            var chunks: [SpeechRegion] = []
            var chunkOffset = 0
            while chunkOffset < totalMs {
                let end = min(chunkOffset + chunkMs, totalMs)
                chunks.append(SpeechRegion(startMs: chunkOffset, endMs: end))
                chunkOffset = end
            }
            speechRegions = chunks
            AppLog.transcribe.info("VAD バイパス: \(chunks.count) チャンク (\(chunkMs)ms 単位)")
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.reconcileVADOutput(chunks, in: store, language: primaryLang)
            }
        } else {
            let vadProgressCb: @Sendable (Double) -> Void = { [weak self] p in
                Task { @MainActor in
                    self?.status = .loadingModel(
                        progress: 0.3 + p * 0.15,
                        message: "[2/4] 発話区間を検出中… \(Int(p * 100))%"
                    )
                }
            }
            let vadCumulativeCb: @Sendable ([SpeechRegion]) -> Void = { [weak self] cumulative in
                Task { @MainActor in
                    guard let self else { return }
                    self.reconcileVADOutput(cumulative, in: store, language: primaryLang)
                }
            }
            let vadSensitivity2 = effectiveSettings.vadSensitivity
            let vadCalibration2 = effectiveSettings.vadCalibration
            do {
                if useEnergyVAD {
                    speechRegions = try await vad.detectSpeechEnergyOnly(
                        samples: samples,
                        sampleRate: 16_000,
                        sensitivity: vadSensitivity2,
                        calibration: vadCalibration2,
                        progress: vadProgressCb,
                        onCumulativeUpdate: vadCumulativeCb,
                        onRegionFinalized: { _ in }
                    )
                } else {
                    speechRegions = try await vad.detectSpeech(
                        samples: samples,
                        sampleRate: 16_000,
                        sensitivity: vadSensitivity2,
                        calibration: vadCalibration2,
                        progress: vadProgressCb,
                        onCumulativeUpdate: vadCumulativeCb,
                        onRegionFinalized: { _ in }
                    )
                }
            } catch {
                throw error
            }
        }
        try Task.checkCancellation()
        AppLog.transcribe.info("VAD 完了: \(speechRegions.count) 発話区間検出")
        if effectiveSettings.vadMethod == .silero {
            vad.unloadModel()
        }

        guard !speechRegions.isEmpty else {
            AppLog.transcribe.info("発話区間なし。空で終了")
            return []
        }

        // --- Phase 3: 各区間の音声から言語を検出 ---
        await MainActor.run { [weak self] in
            self?.status = .correcting(phase: .analyzing, progress: "[3/4] 音声言語を判定中… 0/\(speechRegions.count)")
        }

        // 各 SpeechRegion に検出言語を紐付ける
        struct TaggedSpeechRegion {
            let region: SpeechRegion
            var detectedLanguage: String
        }

        var taggedSpeech: [TaggedSpeechRegion] = []

        for (i, sr) in speechRegions.enumerated() {
            try Task.checkCancellation()

            let startSample = max(0, sr.startMs * 16_000 / 1000)
            let endSample = min(samples.count, sr.endMs * 16_000 / 1000)
            guard startSample < endSample else {
                taggedSpeech.append(TaggedSpeechRegion(region: sr, detectedLanguage: primaryLang))
                continue
            }
            let chunk = Array(samples[startSample..<endSample])

            // 短すぎる (0.25 秒未満) チャンクは言語検出が不安定なので主言語にフォールバック
            guard chunk.count >= 16_000 / 4 else {
                taggedSpeech.append(TaggedSpeechRegion(region: sr, detectedLanguage: primaryLang))
                AppLog.transcribe.debug("言語検出スキップ (短すぎ \(chunk.count) samples) [\(sr.startMs)-\(sr.endMs)] → \(primaryLang, privacy: .public)")
                continue
            }

            var detectedLang: String = primaryLang

            // 音声ベース言語検出 (WhisperKit detectLanguage)
            if let result = try? await engine.detectLanguage(samples: chunk, sampleRate: 16_000) {
                // 候補言語でフィルタ: 確率最大の候補言語を採用
                let filtered = result.langProbs.filter { candidateLanguages.contains($0.key) }
                if let best = filtered.max(by: { $0.value < $1.value }), best.value > 0.1 {
                    detectedLang = best.key
                    let probStr = filtered.map { "\($0.key):\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
                    AppLog.transcribe.debug("音声言語検出 [\(sr.startMs)-\(sr.endMs)]: best=\(best.key, privacy: .public) probs=\(probStr, privacy: .public)")
                }
            }

            taggedSpeech.append(TaggedSpeechRegion(region: sr, detectedLanguage: detectedLang))

            await MainActor.run { [weak self] in
                self?.status = .correcting(phase: .analyzing, progress: "[3/4] 音声言語を判定中… \(i + 1)/\(speechRegions.count)")
            }
        }

        // 言語ごとの統計をログ出力
        let langCounts = Dictionary(grouping: taggedSpeech, by: { $0.detectedLanguage })
            .mapValues { $0.count }
        let statsStr = langCounts.map { "\($0.key):\($0.value)" }.joined(separator: " ")
        AppLog.transcribe.info("言語検出完了: \(statsStr)")

        // --- Phase 4: 検出言語を指定して各区間を ASR ---
        await MainActor.run { [weak self] in
            self?.status = .transcribing(progress: 0)
        }

        var resultRegions: [CaptionRegion] = []
        var consecutiveEmpty = 0
        var currentEngine = engine
        let engineType = PreferencesStore.shared.sttEngine

        for (i, tagged) in taggedSpeech.enumerated() {
            try Task.checkCancellation()
            let sr = tagged.region
            let lang = tagged.detectedLanguage

            let durationMs = sr.endMs - sr.startMs
            if durationMs < effectiveSettings.minSegmentMs {
                AppLog.transcribe.debug("ASR スキップ (短すぎ \(durationMs)ms < \(effectiveSettings.minSegmentMs)ms) [\(sr.startMs)-\(sr.endMs)]")
                healthTracker?.recordASRSkipped()
                continue
            }

            let startSample = max(0, sr.startMs * 16_000 / 1000)
            let endSample = min(samples.count, sr.endMs * 16_000 / 1000)
            guard startSample < endSample else { continue }

            let chunk = await Task.detached(priority: .userInitiated) { () -> [Float] in
                Array(samples[startSample..<endSample])
            }.value

            var asrResult: ASRResult = .failed
            do {
                let text = try await currentEngine.transcribeSamples(
                    samples: chunk,
                    sampleRate: 16_000,
                    language: lang
                )
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                asrResult = .text(trimmed)
                healthTracker?.recordASR(empty: trimmed.isEmpty)
                let region = CaptionRegion(
                    startMs: sr.startMs,
                    endMs: sr.endMs,
                    text: trimmed,
                    isManuallyEdited: false,
                    sourceLanguage: lang,
                    confidence: trimmed.isEmpty ? 0 : 1.0
                )
                resultRegions.append(region)

                if !trimmed.isEmpty {
                    let langName = Self.languageDisplayName(lang)
                    AppLog.transcribe.info("ASR 完了 [\(sr.startMs)-\(sr.endMs)] \(langName): \"\(trimmed.prefix(40), privacy: .public)\"")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.transcribe.error("ASR 失敗 [\(sr.startMs)-\(sr.endMs)]: \(error.localizedDescription, privacy: .public)")
                asrResult = .failed
                healthTracker?.recordASRFailed()
                resultRegions.append(CaptionRegion(
                    startMs: sr.startMs,
                    endMs: sr.endMs,
                    text: "",
                    isManuallyEdited: false,
                    sourceLanguage: lang,
                    confidence: 0
                ))
            }

            // 連続空/失敗検出 → エンジン再初期化
            if asrResult.isEffectivelyEmpty && durationMs > 500 {
                consecutiveEmpty += 1
                NSLog("[ASR-ML] 空/失敗 #%d [%d-%d] result=%@", consecutiveEmpty, sr.startMs, sr.endMs, "\(asrResult)")
            } else {
                consecutiveEmpty = 0
            }

            if consecutiveEmpty >= 2 {
                NSLog("[ASR-ML] 連続空/失敗 %d 回検出 — エンジン再初期化", consecutiveEmpty)
                let newEngine = Self.makeEngine(for: engineType)
                do {
                    try await newEngine.prepare { _ in }
                    currentEngine = newEngine
                    await MainActor.run { [weak self] in self?.engine = newEngine }
                    healthTracker?.recordEngineRestart(success: true)
                    NSLog("[ASR-ML] エンジン再初期化完了")
                } catch {
                    healthTracker?.recordEngineRestart(success: false)
                    NSLog("[ASR-ML] エンジン再初期化失敗: %@", error.localizedDescription)
                }
                consecutiveEmpty = 0
            }

            // 進捗更新 + 中間結果を store に反映
            let progress = Double(i + 1) / Double(taggedSpeech.count)
            await MainActor.run { [weak self] in
                self?.status = .transcribing(progress: progress)
                self?.mergeAndCommit(newRegions: resultRegions, store: store)
                if let lastID = store.project?.editor.captionRegions.last?.id {
                    store.scrollToRegionID = lastID
                }
            }
        }

        // 最終結果を store に反映 + 空リージョン除去
        await MainActor.run { [weak self] in
            self?.mergeAndCommit(newRegions: resultRegions, store: store)
            self?.purgeEmptyRegions(in: store)
        }

        AppLog.transcribe.info("多言語パイプライン完了: \(resultRegions.count) regions")
        return await MainActor.run { store.project?.editor.captionRegions ?? [] }
    }

    static func languageDisplayName(_ code: String) -> String {
        switch code {
        case "ja": return "日本語"
        case "en": return "English"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "it": return "Italiano"
        case "es": return "Español"
        case "auto": return "自動検出"
        default: return code
        }
    }

    /// パイプライン進捗状態を UI に反映する。
    /// VAD と ASR の両方からトリガされるので、最新のスナップショットで status を更新する。
    @MainActor
    private func publishPipelineProgress(progressBox: PipelineProgressBox) async {
        guard !Task.isCancelled else { return }
        let asr = progressBox.asrDone
        let total = max(asr, progressBox.vadDetectedCount, 1)
        // overall = (VAD進捗 * 0.4) + (ASR進捗 * 0.6) という重みづけ
        let vadFrac = progressBox.vadProgress
        let asrFrac = Double(asr) / Double(max(1, progressBox.vadDetectedCount))
        let overall = vadFrac * 0.4 + asrFrac * 0.6
        let msg = "VAD \(Int(vadFrac * 100))% / 文字起こし \(asr)/\(progressBox.vadDetectedCount)"
        // .transcribing はテキスト持てないので、loadingModel 風に message も含めたいが
        // 既存 UI 側を維持して .transcribing(progress:) を使う。詳細は別 UI 改修で。
        self.status = .transcribing(progress: max(0, min(1, overall)))
        AppLog.transcribe.debug("\(msg)")
    }

    /// store から、指定 SpeechRegion と時間が重なる既存 CaptionRegion を 1 件返す。
    /// VAD 後の ASR フェーズで、VAD が作った空 region の UUID を引き継ぐために使う。
    private func findRegion(in store: ProjectStore, overlapping sr: SpeechRegion) -> CaptionRegion? {
        guard let regions = store.project?.editor.captionRegions else { return nil }
        return regions.first { r in
            r.startMs < sr.endMs && sr.startMs < r.endMs
        }
    }

    private static func makeEngine(for type: STTEngineType) -> CaptionEngine {
        switch type {
        case .whisper:       return WhisperKitCaptionEngine()
        case .parakeet:      return ParakeetCaptionEngine()
        case .qwen3:         return Qwen3CaptionEngine()
        case .fasterWhisper: return FasterWhisperCaptionEngine()
        }
    }

    @MainActor
    private func getRegionText(in store: ProjectStore, matching sr: SpeechRegion) -> String? {
        findRegion(in: store, overlapping: sr)?.text
    }

    // MARK: - Pipeline helpers (VAD + ASR 並行実行用)

    /// VAD の累積発話区間から CaptionRegion 列を再構築して store に commit する。
    /// 既に同じ範囲を覆う CaptionRegion があれば、UUID と text を保持したまま境界だけ更新する。
    /// これで ASR が既に埋めた text が VAD 側の更新で消えない。
    private func reconcileVADOutput(_ vadRegions: [SpeechRegion], in store: ProjectStore, language: String) {
        guard var state = store.project?.editor else { return }
        let existing = state.captionRegions
        let protected = existing.filter { $0.isManuallyEdited }

        var newList: [CaptionRegion] = []
        for sr in vadRegions {
            if protected.contains(where: { $0.startMs < sr.endMs && sr.startMs < $0.endMs }) {
                continue
            }
            if let match = existing.first(where: { r in
                !r.isManuallyEdited && r.startMs < sr.endMs && sr.startMs < r.endMs
            }) {
                // テキスト入り region は境界を凍結する。
                // テキストはその境界の音声に対して生成されたものなので、
                // 境界を変えるならテキストも無効になる。
                if !match.text.isEmpty {
                    newList.append(match)
                } else {
                    var updated = match
                    updated.startMs = sr.startMs
                    updated.endMs = sr.endMs
                    newList.append(updated)
                }
            } else {
                newList.append(CaptionRegion(
                    startMs: sr.startMs,
                    endMs: sr.endMs,
                    text: "",
                    isManuallyEdited: false,
                    sourceLanguage: language,
                    confidence: 0
                ))
            }
        }

        let combined = (newList + protected).sorted { $0.startMs < $1.startMs }
        state.captionRegions = combined
        store.commitState(state)
    }

    /// ASR の認識結果を、対応する CaptionRegion の text に書き込む (UUID 保持)。
    /// 該当 region は startMs/endMs の重なりで特定する。
    private func updateRegionText(in store: ProjectStore, matching sr: SpeechRegion, text: String) {
        guard var state = store.project?.editor else { return }
        guard let idx = state.captionRegions.firstIndex(where: { r in
            !r.isManuallyEdited && r.startMs < sr.endMs && sr.startMs < r.endMs
        }) else {
            NSLog("[ASR] updateRegionText: マッチなし — text='%@' sr=[%d-%d]",
                  text.prefix(40).description, sr.startMs, sr.endMs)
            healthTracker?.recordWrite(matched: false)
            return
        }
        healthTracker?.recordWrite(matched: true)
        let region = state.captionRegions[idx]
        let updated = CaptionRegion(
            id: region.id,
            startMs: region.startMs,
            endMs: region.endMs,
            text: text,
            translatedText: region.translatedText,
            translatedLanguage: region.translatedLanguage,
            isManuallyEdited: region.isManuallyEdited,
            sourceLanguage: region.sourceLanguage,
            confidence: text.isEmpty ? 0 : 1.0,
            corrections: region.corrections,
            originalRawText: region.originalRawText,
            engineResults: region.engineResults
        )
        state.captionRegions[idx] = updated
        store.commitState(state)
        store.scrollToRegionID = updated.id
    }

    /// ASR 後に空のまま残ったリージョンを store から除去する。
    /// 手修正済み (isManuallyEdited) は保護する。
    /// - Returns: 除去した件数
    @discardableResult
    private func purgeEmptyRegions(in store: ProjectStore) -> Int {
        guard var state = store.project?.editor else { return 0 }
        let before = state.captionRegions.count
        state.captionRegions.removeAll { r in
            !r.isManuallyEdited && r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let removed = before - state.captionRegions.count
        if removed > 0 {
            store.commitState(state)
            NSLog("[Pipeline] 空リージョン %d 件を除去 (残り %d 件)", removed, state.captionRegions.count)
        }
        return removed
    }

    /// ASR の結果ステータス。空検出ロジックで使う。
    private enum ASRResult {
        case text(String)   // 認識成功 (空文字含む)
        case skipped        // 短すぎ等でスキップ
        case failed         // エンジン例外
        case cancelled      // キャンセル

        var isEffectivelyEmpty: Bool {
            switch self {
            case .text(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .failed:      return true
            case .skipped, .cancelled: return false
            }
        }
    }

    /// 1 つの SpeechRegion を ASR エンジンに投げて text を取得し、store に反映する。
    /// 結果を ASRResult で返す — 呼び元で空検出に使う。
    private func processOneSpeechRegion(
        _ sr: SpeechRegion,
        engine: CaptionEngine,
        samples: [Float],
        language: String,
        store: ProjectStore,
        minDurationMs: Int = 250
    ) async -> ASRResult {
        let durationMs = sr.endMs - sr.startMs
        if durationMs < minDurationMs {
            AppLog.transcribe.debug("ASR skip (短すぎ \(durationMs)ms < \(minDurationMs)ms): [\(sr.startMs)-\(sr.endMs)]")
            return .skipped
        }

        let startSample = max(0, sr.startMs * 16_000 / 1000)
        let endSample = min(samples.count, sr.endMs * 16_000 / 1000)
        guard startSample < endSample else { return .skipped }

        let chunk = await Task.detached(priority: .userInitiated) { () -> [Float] in
            Array(samples[startSample..<endSample])
        }.value

        let asrStart = Date()
        do {
            let text = try await engine.transcribeSamples(
                samples: chunk,
                sampleRate: 16_000,
                language: language
            )
            let asrElapsed = Date().timeIntervalSince(asrStart)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.transcribe.info("ASR done [\(sr.startMs)-\(sr.endMs)] \(String(format: "%.2f", asrElapsed))s: \"\(trimmed.prefix(40), privacy: .public)\"")
            await MainActor.run { [weak self] in
                self?.updateRegionText(in: store, matching: sr, text: trimmed)
            }
            return .text(trimmed)
        } catch is CancellationError {
            AppLog.transcribe.notice("ASR キャンセル [\(sr.startMs)-\(sr.endMs)]")
            return .cancelled
        } catch {
            AppLog.transcribe.error("ASR 失敗 [\(sr.startMs)-\(sr.endMs)]: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    // MARK: - Merge

    /// 新 segment 列と既存 captionRegions を保護フラグ単位で merge して commit する。
    /// 手修正済み region は完全に保護し、それ以外は新 region で置き換える。
    /// 既存 region に翻訳結果や校正情報がある場合は新 region に引き継ぐ。
    private func mergeAndCommit(newRegions: [CaptionRegion], store: ProjectStore) {
        guard var state = store.project?.editor else { return }
        let existing = state.captionRegions

        func overlaps(_ a: CaptionRegion, _ b: CaptionRegion) -> Bool {
            a.startMs < b.endMs && b.startMs < a.endMs
        }

        let protected = existing.filter { $0.isManuallyEdited }

        var merged: [CaptionRegion] = protected
        for var n in newRegions {
            if protected.contains(where: { overlaps($0, n) }) { continue }

            if let match = existing.first(where: { overlaps($0, n) && !$0.isManuallyEdited }) {
                if n.translatedText == nil { n.translatedText = match.translatedText }
                if n.translatedLanguage == nil { n.translatedLanguage = match.translatedLanguage }
                if n.corrections.isEmpty { n.corrections = match.corrections }
                if n.originalRawText == nil { n.originalRawText = match.originalRawText }
            }
            merged.append(n)
        }
        merged.sort { $0.startMs < $1.startMs }
        state.captionRegions = merged
        store.commitState(state)
    }

    // MARK: - Audio source resolution

    private func resolveAudioURL(store: ProjectStore) -> URL? {
        guard let media = store.project?.media else { return nil }
        // YouTube モード: キャプチャ済み音声ファイルを優先
        if let capturedPath = media.capturedAudioPath,
           !capturedPath.isEmpty,
           FileManager.default.fileExists(atPath: capturedPath) {
            return URL(fileURLWithPath: capturedPath)
        }
        if !media.screenVideoPath.isEmpty,
           FileManager.default.fileExists(atPath: media.screenVideoPath) {
            return URL(fileURLWithPath: media.screenVideoPath)
        }
        return nil
    }

    // MARK: - Audio slice extraction (アンサンブルチェック用)

    /// 指定範囲の音声を [Float] (Float32 PCM, mono) として抽出する。
    /// AudioCommon の AudioFileLoader を使う (主エンジン経路と同じ実装)。
    ///
    /// 注意: 現状は毎回ファイル全体をロードしてからスライスする実装。
    /// 30 分動画でも数百MB の Float 配列、メモリ的には問題なし。
    /// 同じ動画に対する複数チャンク抽出ではキャッシュが望ましいが、
    /// オンデマンド単発実行なので現状は素朴な実装で十分。
    static func extractAudioSlice(
        url: URL,
        startMs: Int,
        endMs: Int,
        targetSampleRate: Int
    ) async throws -> [Float] {
        let all: [Float]
        do {
            all = try AudioFileLoader.load(url: url, targetSampleRate: targetSampleRate)
        } catch {
            throw CaptionEngineError.audioLoadFailed("\(error.localizedDescription)")
        }
        let startSample = max(0, startMs * targetSampleRate / 1000)
        let endSample = min(all.count, endMs * targetSampleRate / 1000)
        guard startSample < endSample else { return [] }
        return Array(all[startSample..<endSample])
    }

    // MARK: - VAD キャリブレーション

    /// 指定区間の RMS を測定する（VAD キャリブレーション用）。
    /// 局所 AGC 正規化後の値を返すので、VAD 実行時と同じ条件で測定できる。
    static func measureRMS(url: URL, startMs: Int, endMs: Int) async throws -> Float {
        let samples = try await extractAudioSlice(
            url: url, startMs: startMs, endMs: endMs, targetSampleRate: 16_000
        )
        return EnergyVAD.measureRMS(samples: samples, sampleRate: 16_000, startMs: 0, endMs: endMs - startMs)
    }

    // MARK: - Memory monitoring

    /// プロセスのメモリ使用量を取得する (bytes)
    static func currentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    /// システムの物理メモリ総量 (bytes)
    static let totalPhysicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// メモリ使用率を 0.0–1.0 で返す
    static func memoryPressure() -> Double {
        let used = currentMemoryUsage()
        guard totalPhysicalMemory > 0 else { return 0 }
        return Double(used) / Double(totalPhysicalMemory)
    }

    /// メモリ状態をログに出力する
    static func logMemoryState(context: String) {
        let usedMB = Double(currentMemoryUsage()) / 1_048_576.0
        let totalMB = Double(totalPhysicalMemory) / 1_048_576.0
        let pressure = memoryPressure()
        let level: String
        switch pressure {
        case 0..<0.5: level = "normal"
        case 0.5..<0.7: level = "elevated"
        case 0.7..<0.85: level = "high"
        default: level = "CRITICAL"
        }
        NSLog("[Memory] %@: %.0fMB / %.0fMB (%.1f%%) [%@]", context, usedMB, totalMB, pressure * 100, level)
    }
}
