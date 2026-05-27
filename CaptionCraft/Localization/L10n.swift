import Foundation

// MARK: - L10n

/// 型安全なローカライズ文字列アクセス。
/// Localizable.strings (en.lproj / ja.lproj) のキーをラップする。
///
/// 成熟度: experimental
enum L10n {

    static func intent() -> String {
        """
        役割: NSLocalizedString のラッパー。全 UI 文字列を一元管理する。
        成熟度: experimental
        依存: Localizable.strings (en.lproj, ja.lproj)
        変更時の注意: キーを追加したら en/ja 両方の .strings に対応エントリを追加すること。
        """
    }

    // MARK: - App Menu

    enum App {
        static let about = NSLocalizedString("app.menu.about", comment: "")
        static let newProject = NSLocalizedString("app.menu.new_project", comment: "")
        static let openProject = NSLocalizedString("app.menu.open_project", comment: "")
        static let saveProject = NSLocalizedString("app.menu.save_project", comment: "")
        static let saveProjectAs = NSLocalizedString("app.menu.save_project_as", comment: "")
        static let openVideo = NSLocalizedString("app.menu.open_video", comment: "")
        static let openYouTubeURL = NSLocalizedString("app.menu.open_youtube_url", comment: "")
        static let importSRT = NSLocalizedString("app.menu.import_srt", comment: "")
        static let exportSRT = NSLocalizedString("app.menu.export_srt", comment: "")
        static let undo = NSLocalizedString("app.menu.undo", comment: "")
        static let redo = NSLocalizedString("app.menu.redo", comment: "")
        static let recentDocuments = NSLocalizedString("app.menu.recent_documents", comment: "")
        static let noRecentDocuments = NSLocalizedString("app.menu.no_recent_documents", comment: "")
        static let clearRecentDocuments = NSLocalizedString("app.menu.clear_recent_documents", comment: "")

        // アラート
        static let unsavedTitle = NSLocalizedString("app.alert.unsaved_title", comment: "")
        static func unsavedSingle(_ name: String) -> String {
            String(format: NSLocalizedString("app.alert.unsaved_single", comment: ""), name)
        }
        static func unsavedMultiple(_ count: Int) -> String {
            String(format: NSLocalizedString("app.alert.unsaved_multiple", comment: ""), count)
        }
        static let saveAndQuit = NSLocalizedString("app.alert.save_and_quit", comment: "")
        static let quitWithoutSaving = NSLocalizedString("app.alert.quit_without_saving", comment: "")
        static let selectProject = NSLocalizedString("app.alert.select_project", comment: "")
        static let selectVideo = NSLocalizedString("app.alert.select_video", comment: "")
    }

    // MARK: - About

    enum About {
        static let title = NSLocalizedString("about.title", comment: "")
        static func version(_ version: String, _ build: String) -> String {
            String(format: NSLocalizedString("about.version", comment: ""), version, build)
        }
        static let copyright = NSLocalizedString("about.copyright", comment: "")
        static let tabOverview = NSLocalizedString("about.tab.overview", comment: "")
        static let tabLicense = NSLocalizedString("about.tab.license", comment: "")
        static let description = NSLocalizedString("about.description", comment: "")
        static let descriptionDetail = NSLocalizedString("about.description_detail", comment: "")
        static let licenseHeader = NSLocalizedString("about.license_header", comment: "")
    }

    // MARK: - Editor

    enum Editor {
        static let title = NSLocalizedString("editor.title", comment: "")
        static let titleUntitled = NSLocalizedString("editor.title_untitled", comment: "")

        // SRT ダイアログ
        static let srtSelectFile = NSLocalizedString("editor.srt.select_file", comment: "")
        static let srtNoSubtitlesTitle = NSLocalizedString("editor.srt.no_subtitles_title", comment: "")
        static let srtNoSubtitlesMessage = NSLocalizedString("editor.srt.no_subtitles_message", comment: "")
        static let srtReplaceTitle = NSLocalizedString("editor.srt.replace_title", comment: "")
        static func srtReplaceMessage(existing: Int, imported: Int) -> String {
            String(format: NSLocalizedString("editor.srt.replace_message", comment: ""), existing, imported)
        }
        static let srtReplace = NSLocalizedString("editor.srt.replace", comment: "")
        static let srtNoExportTitle = NSLocalizedString("editor.srt.no_export_title", comment: "")
        static let srtNoExportMessage = NSLocalizedString("editor.srt.no_export_message", comment: "")
        static let srtSaveLocation = NSLocalizedString("editor.srt.save_location", comment: "")

        // 閉じるダイアログ
        static let closeSaveTitle = NSLocalizedString("editor.close.save_title", comment: "")
        static let closeSaveMessage = NSLocalizedString("editor.close.save_message", comment: "")
        static let closeSave = NSLocalizedString("editor.close.save", comment: "")
        static let closeDiscard = NSLocalizedString("editor.close.discard", comment: "")
    }

    // MARK: - Caption / Whisper

    enum Caption {
        static let whisperTitle = NSLocalizedString("caption.whisper.title", comment: "")
        static let whisperLanguage = NSLocalizedString("caption.whisper.language", comment: "")
        static let whisperLangJa = NSLocalizedString("caption.whisper.lang_ja", comment: "")
        static let whisperLangEn = NSLocalizedString("caption.whisper.lang_en", comment: "")
        static let whisperLangAuto = NSLocalizedString("caption.whisper.lang_auto", comment: "")
        static let whisperSilenceThreshold = NSLocalizedString("caption.whisper.silence_threshold", comment: "")
        static let whisperMaxWords = NSLocalizedString("caption.whisper.max_words", comment: "")
        static let whisperSynthesizeAll = NSLocalizedString("caption.whisper.synthesize_all", comment: "")
        static let whisperNoVideo = NSLocalizedString("caption.whisper.no_video", comment: "")
        static let whisperLoadingModel = NSLocalizedString("caption.whisper.loading_model", comment: "")
        static let whisperTranscribing = NSLocalizedString("caption.whisper.transcribing", comment: "")

        // リージョンエディタ
        static let regionSelectPrompt = NSLocalizedString("caption.region.select_prompt", comment: "")
        static let regionText = NSLocalizedString("caption.region.text", comment: "")
        static let regionResynthesize = NSLocalizedString("caption.region.resynthesize", comment: "")
        static let regionDelete = NSLocalizedString("caption.region.delete", comment: "")
        static let regionListenLoop = NSLocalizedString("caption.region.listen_loop", comment: "")
        static let regionClearCache = NSLocalizedString("caption.region.clear_cache", comment: "")
        static func regionCacheCount(_ count: Int) -> String {
            String(format: NSLocalizedString("caption.region.cache_count", comment: ""), count)
        }
        static let regionListening = NSLocalizedString("caption.region.listening", comment: "")
        static let regionPreparing = NSLocalizedString("caption.region.preparing", comment: "")
        static let regionManuallyEdited = NSLocalizedString("caption.region.manually_edited", comment: "")
        static func regionLowConfidence(_ pct: Double) -> String {
            String(format: NSLocalizedString("caption.region.low_confidence", comment: ""), pct)
        }
        static func regionAutoSynthesized(_ pct: Double) -> String {
            String(format: NSLocalizedString("caption.region.auto_synthesized", comment: ""), pct)
        }

        // 辞書候補バナー
        static let dictDetected = NSLocalizedString("caption.dict.detected", comment: "")
        static func dictOtherMatches(_ count: Int) -> String {
            String(format: NSLocalizedString("caption.dict.other_matches", comment: ""), count)
        }
        static let dictFixAll = NSLocalizedString("caption.dict.fix_all", comment: "")
        static let dictRegisterOnly = NSLocalizedString("caption.dict.register_only", comment: "")
        static let dictIgnore = NSLocalizedString("caption.dict.ignore", comment: "")
    }

    // MARK: - Caption List

    enum CaptionList {
        static let empty = NSLocalizedString("captionlist.empty", comment: "")
        static let llmCorrection = NSLocalizedString("captionlist.llm_correction", comment: "")
        static let translate = NSLocalizedString("captionlist.translate", comment: "")
        static let addAtPosition = NSLocalizedString("captionlist.add_at_position", comment: "")
        static let seekTo = NSLocalizedString("captionlist.seek_to", comment: "")
        static let deleteSubtitle = NSLocalizedString("captionlist.delete_subtitle", comment: "")
    }

    // MARK: - Correction History

    enum Correction {
        static let title = NSLocalizedString("correction.title", comment: "")
        static let filterSelected = NSLocalizedString("correction.filter.selected", comment: "")
        static let filterAll = NSLocalizedString("correction.filter.all", comment: "")
        static let empty = NSLocalizedString("correction.empty", comment: "")
        static let original = NSLocalizedString("correction.original", comment: "")
        static let filterBtnAll = NSLocalizedString("correction.filter_btn.all", comment: "")
        static let filterBtnDict = NSLocalizedString("correction.filter_btn.dict", comment: "")
        static let filterBtnLLM = NSLocalizedString("correction.filter_btn.llm", comment: "")
        static let filterBtnManual = NSLocalizedString("correction.filter_btn.manual", comment: "")
        static func summary(total: Int, dict: Int, llm: Int, manual: Int) -> String {
            String(format: NSLocalizedString("correction.summary", comment: ""), total, dict, llm, manual)
        }
    }

    // MARK: - Dictionary Manager

    enum Dict {
        static let title = NSLocalizedString("dict.title", comment: "")
        static let domainHint = NSLocalizedString("dict.domain_hint", comment: "")
        static let empty = NSLocalizedString("dict.empty", comment: "")
        static func entryCount(_ count: Int) -> String {
            String(format: NSLocalizedString("dict.entry_count", comment: ""), count)
        }
        static func useCount(_ count: Int) -> String {
            String(format: NSLocalizedString("dict.use_count", comment: ""), count)
        }
        static let newEntry = NSLocalizedString("dict.new_entry", comment: "")
        static let add = NSLocalizedString("dict.add", comment: "")
        static let addEntry = NSLocalizedString("dict.add_entry", comment: "")
    }

    // MARK: - Translation Panel

    enum Translation {
        static let title = NSLocalizedString("translation.title", comment: "")
        static let server = NSLocalizedString("translation.server", comment: "")
        static let serverPlaceholder = NSLocalizedString("translation.server_placeholder", comment: "")
        static let model = NSLocalizedString("translation.model", comment: "")
        static let refreshModels = NSLocalizedString("translation.refresh_models", comment: "")
        static let fetching = NSLocalizedString("translation.fetching", comment: "")
        static let serverDisconnected = NSLocalizedString("translation.server_disconnected", comment: "")
        static let notInstalled = NSLocalizedString("translation.not_installed", comment: "")
        static let notInstalledDetail = NSLocalizedString("translation.not_installed_detail", comment: "")
        static let downloadLMStudio = NSLocalizedString("translation.download_lmstudio", comment: "")
        static let notRunning = NSLocalizedString("translation.not_running", comment: "")
        static let notRunningDetail = NSLocalizedString("translation.not_running_detail", comment: "")
        static let launchLMStudio = NSLocalizedString("translation.launch_lmstudio", comment: "")
        static let noModelLoaded = NSLocalizedString("translation.no_model_loaded", comment: "")
        static let noModelLoadedDetail = NSLocalizedString("translation.no_model_loaded_detail", comment: "")
        static let openLMStudio = NSLocalizedString("translation.open_lmstudio", comment: "")
        static let autoLoading = NSLocalizedString("translation.auto_loading", comment: "")
        static let autoLoadingWait = NSLocalizedString("translation.auto_loading_wait", comment: "")
        static let loadLastModel = NSLocalizedString("translation.load_last_model", comment: "")
        static func lastUsedModel(_ name: String) -> String {
            String(format: NSLocalizedString("translation.last_used_model", comment: ""), name)
        }
        static let targetLanguage = NSLocalizedString("translation.target_language", comment: "")
        static let translateAll = NSLocalizedString("translation.translate_all", comment: "")
        static let noSubtitles = NSLocalizedString("translation.no_subtitles", comment: "")
    }

    // MARK: - Right Panel

    enum Panel {
        static let translation = NSLocalizedString("panel.translation", comment: "")
        static let correction = NSLocalizedString("panel.correction", comment: "")
        static let llmCorrection = NSLocalizedString("panel.llm_correction", comment: "")
        static let runCorrection = NSLocalizedString("panel.run_correction", comment: "")
        static let correctionHelp = NSLocalizedString("panel.correction_help", comment: "")
    }

    // MARK: - Timeline

    enum Timeline {
        static let translation = NSLocalizedString("timeline.translation", comment: "")
        static let preCorrection = NSLocalizedString("timeline.pre_correction", comment: "")
        static let postCorrection = NSLocalizedString("timeline.post_correction", comment: "")
        static let followPlayhead = NSLocalizedString("timeline.follow_playhead", comment: "")
        static let zoomOut = NSLocalizedString("timeline.zoom_out", comment: "")
        static let fitToView = NSLocalizedString("timeline.fit_to_view", comment: "")
        static let zoomIn = NSLocalizedString("timeline.zoom_in", comment: "")
        static let llmCorrection = NSLocalizedString("timeline.llm_correction", comment: "")
        static let translate = NSLocalizedString("timeline.translate", comment: "")
        static let noPreCorrection = NSLocalizedString("timeline.no_pre_correction", comment: "")
        static let uncorrected = NSLocalizedString("timeline.uncorrected", comment: "")
    }

    // MARK: - Preferences

    enum Prefs {
        enum General {
            static let reset = NSLocalizedString("prefs.general.reset", comment: "")
        }
    }

    // MARK: - Errors

    enum Error {
        static func network(_ msg: String) -> String {
            String(format: NSLocalizedString("error.network", comment: ""), msg)
        }
        static func api(_ code: Int, _ body: String) -> String {
            String(format: NSLocalizedString("error.api", comment: ""), code, body)
        }
        static func parse(_ msg: String) -> String {
            String(format: NSLocalizedString("error.parse", comment: ""), msg)
        }
        static let unknownResponse = NSLocalizedString("error.unknown_response", comment: "")
        static let modelListParse = NSLocalizedString("error.model_list_parse", comment: "")
        static let responseParse = NSLocalizedString("error.response_parse", comment: "")
        static let noLLM = NSLocalizedString("error.no_llm", comment: "")
        static let contextEncodeFailed = NSLocalizedString("error.context_encode_failed", comment: "")
        static let contextUnknown = NSLocalizedString("error.context_unknown", comment: "")
    }

    // MARK: - Progress

    enum Progress {
        static let contextInference = NSLocalizedString("progress.context_inference", comment: "")
        static func correcting(done: Int, total: Int) -> String {
            String(format: NSLocalizedString("progress.correcting", comment: ""), done, total)
        }
        static let correctingSingle = NSLocalizedString("progress.correcting_single", comment: "")
        static let done = NSLocalizedString("progress.done", comment: "")
        static let translating = NSLocalizedString("progress.translating", comment: "")
        static func translatingCount(done: Int, total: Int) -> String {
            String(format: NSLocalizedString("progress.translating_count", comment: ""), done, total)
        }
    }

    // MARK: - Common

    enum Common {
        static let cancel = NSLocalizedString("common.cancel", comment: "")
        static let arrow = NSLocalizedString("common.arrow", comment: "")
        static let retry = NSLocalizedString("common.retry", comment: "")
    }
}
