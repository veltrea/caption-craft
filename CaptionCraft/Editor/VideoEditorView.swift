import SwiftUI

/// CaptionCraft エディタウィンドウのルートレイアウト。
///
/// CC Phase 03 で動画編集系 (TopToolbar / IconRail / FloatingPanel / Annotation / TTS /
/// BGM / Narration / Zoom UI) を全削除し、字幕作成に必要な 3 ペイン構成 (左: 動画
/// プレビュー、右: 字幕パネル、下: 再生コントロール + 字幕リスト) に簡素化した。
///
/// CC Phase 04 以降で UI デザインを CaptionCraft 用に整え直す予定。
struct VideoEditorView: View {
    @ObservedObject var store:    ProjectStore
    @ObservedObject var playback: PlaybackController
    @ObservedObject var timeline: TimelineViewModel

    /// Caption 字幕合成。主エンジンは環境設定 (PreferencesStore.sttEngine) から取得。
    /// 環境設定で切り替えた場合は .onChange で実行時に engine を差し替える。
    @StateObject private var captionTranscriber = CaptionTranscriber(
        engine: Self.makeEngine(
            for: PreferencesStore.shared.sttEngine,
            variant: PreferencesStore.shared.whisperModelVariant
        )
    )

    @ObservedObject private var prefs = PreferencesStore.shared

    /// 環境設定から主 STT エンジンインスタンスを作る。
    private static func makeEngine(for type: STTEngineType, variant: WhisperModelVariant = .largev3) -> CaptionEngine {
        switch type {
        case .whisper:    return WhisperKitCaptionEngine(modelVariant: variant)
        case .parakeet:   return ParakeetCaptionEngine()
        case .qwen3:      return Qwen3CaptionEngine()
        case .fasterWhisper: return FasterWhisperCaptionEngine()
        }
    }

    /// 校正辞書ストア。アプリ全体で共有する辞書の永続化。
    @StateObject private var dictionaryStore = DictionaryStore()

    /// LLM 校正サービス。CaptionTranscriber と CaptionPanel で共有。
    @StateObject private var correctionService = CorrectionService()

    /// 翻訳サービス。RightPanelView と TimelineView で共有する。
    @StateObject private var translationService = TranslationService()

    /// 波形抽出。動画ロード時にバックグラウンドで PCM を読んで peak 配列を生成する。
    @StateObject private var waveformService = WaveformService()

    /// リモート制御サーバー (Claude から curl で操作するため)。シングルトン。
    private var remoteControl: RemoteControlServer { RemoteControlServer.shared }

    // MARK: - YouTube モード

    @StateObject private var audioDownloader = YouTubeAudioDownloader()
    @State private var youtubeURLText = ""

    private var isYouTubeMode: Bool {
        store.project?.media.isYouTubeMode ?? false
    }

    /// タイムライン領域の高さ。境界線ドラッグで変更可能。
    @State private var timelineHeight: CGFloat = 280

    /// 聴き直しパネルの表示フラグ。ループ開始で自動表示、停止で自動非表示。
    @State private var showListenPanel: Bool = false

    /// 聴き直しパネル用 EQ プロセッサ。AVPlayer のパイプラインに直接挿入する。
    @StateObject private var listenEQProcessor = ListenEQProcessor()

    private static let timelineMinHeight: CGFloat = 150
    private static let timelineMaxHeight: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PreviewAreaView(
                    store: store,
                    playback: playback,
                    timeline: timeline,
                    audioDownloader: audioDownloader,
                    youtubeURLText: $youtubeURLText
                )
                .frame(minWidth: 520, minHeight: 260)
                .background(EditorTheme.canvas)

                Divider()

                RightPanelView(
                    store: store,
                    timeline: timeline,
                    captionTranscriber: captionTranscriber,
                    playback: playback,
                    dictionaryStore: dictionaryStore,
                    correctionService: correctionService,
                    translationService: translationService
                )
                .frame(width: 320)
            }

            Divider()

            PlaybackControlsView(
                store: store,
                playback: playback,
                timeline: timeline,
                audioDownloader: audioDownloader,
                captionTranscriber: captionTranscriber
            )

            TimelineResizeHandle(height: $timelineHeight,
                                 minHeight: Self.timelineMinHeight,
                                 maxHeight: Self.timelineMaxHeight)

            TimelineView(
                store: store,
                playback: playback,
                timeline: timeline,
                waveformService: waveformService,
                correctionService: correctionService,
                dictionaryStore: dictionaryStore,
                translationService: translationService,
                transcriber: captionTranscriber,
                llmEndpoint: captionTranscriber.llmEndpoint
            )
            .frame(height: timelineHeight)
        }
        .overlay {
            if showListenPanel && playback.isSlowLooping {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { playback.stopSlowLoop() }

                ListenPanelView(
                    playback: playback,
                    store: store,
                    eqProcessor: listenEQProcessor,
                    sourceURL: store.project.flatMap { p in
                        let path = p.media.screenVideoPath ?? p.media.capturedAudioPath ?? ""
                        return path.isEmpty ? nil : URL(fileURLWithPath: path)
                    },
                    onClose: { playback.stopSlowLoop() }
                )
            }
        }
        .onChange(of: playback.isSlowLooping) { looping in
            showListenPanel = looping
        }
        .background(EditorTheme.chrome)
        .environment(\.colorScheme, .dark)
        .onChange(of: store.project?.media.screenVideoPath) { newPath in
            // 動画パス変更で波形を再抽出する。
            guard let path = newPath, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { return }
            waveformService.extract(url: URL(fileURLWithPath: path))
        }
        .onChange(of: store.project?.media.capturedAudioPath) { newPath in
            guard let path = newPath, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { return }
            waveformService.extract(url: URL(fileURLWithPath: path))
        }
        .onChange(of: prefs.sttEngine) { newType in
            if captionTranscriber.isRunning {
                captionTranscriber.cancel()
            }
            captionTranscriber.engine = Self.makeEngine(for: newType, variant: prefs.whisperModelVariant)
        }
        .onChange(of: prefs.whisperModelVariant) { newVariant in
            // Whisper モデルバリアント変更時、主エンジンが Whisper なら差し替え。
            guard prefs.sttEngine == .whisper else { return }
            if captionTranscriber.isRunning {
                captionTranscriber.cancel()
            }
            captionTranscriber.engine = Self.makeEngine(for: .whisper, variant: newVariant)
        }
        .onAppear {
            captionTranscriber.dictionaryStore = dictionaryStore
            captionTranscriber.correctionService = correctionService

            // リモート制御サーバーにアクティブウィンドウと全サービスを登録
            remoteControl.register(
                store: store,
                transcriber: captionTranscriber,
                translationService: translationService,
                correctionService: correctionService,
                dictionaryStore: dictionaryStore,
                audioDownloader: audioDownloader
            )

            // 既に動画パスが設定済みなら抽出を起動。
            if let path = store.project?.media.screenVideoPath, !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                waveformService.extract(url: URL(fileURLWithPath: path))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            remoteControl.register(
                store: store,
                transcriber: captionTranscriber,
                translationService: translationService,
                correctionService: correctionService,
                dictionaryStore: dictionaryStore,
                audioDownloader: audioDownloader
            )
        }
        // アンサンブルチェックのモーダルシート。
        // CaptionTranscriber.activeEnsembleSession が non-nil の間、表示される。
        .sheet(item: $captionTranscriber.activeEnsembleSession) { session in
            EnsembleCheckSheet(
                session: session,
                onDismiss: { captionTranscriber.dismissEnsembleSession() },
                onUpdate: { text in captionTranscriber.updateCrossCheckText(text, store: store) }
            )
        }
    }
}
