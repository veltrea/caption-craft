import AVFoundation
import Foundation
import WhisperKit

// MARK: - WhisperKitCaptionEngine

/// CaptionEngine の WhisperKit 実装 (本番用、Phase 1 後半)。
/// モデルは初回 transcribe 時に argmax HuggingFace リポジトリから DL されて
/// `~/Library/Caches/WhisperKit` 配下に自動キャッシュされる。
///
/// 成熟度: experimental (FIX_10 Phase 1, WhisperKit 0.9+)
///
/// 設計メモ:
/// - WhisperKit は `audioPath` を受け取り内部で 16kHz mono に変換するため、
///   こちらで AVAudioConverter を通す必要はない。元 MP4 の URL をそのまま渡せばよい。
/// - モデルサイズは WhisperKit 命名規則に変換する (small → "openai_whisper-small")。
/// - 進捗: WhisperKit の TranscriptionCallback で `progress.timings.inputAudioSeconds` を
///   見て音声総長で割って算出。モデル DL 段階の進捗は granular には取れないため
///   `prepare` では「インスタンス化完了まで 0 → 1」の単純 step を返す。
final class WhisperKitCaptionEngine: CaptionEngine {

    /// 使用するモデルバリアント。init 後に変更した場合は pipeline をリセットする。
    var modelVariant: WhisperModelVariant {
        didSet {
            if oldValue != modelVariant { pipeline = nil }
        }
    }

    private var modelName: String { modelVariant.rawValue }

    private var pipeline: WhisperKit?

    init(modelVariant: WhisperModelVariant = .largev3) {
        self.modelVariant = modelVariant
    }

    func isAvailable() async -> Bool {
        true
    }

    func prepare(
        progress: @MainActor @escaping (Double) -> Void
    ) async throws {
        if pipeline != nil {
            AppLog.caption.info("prepare: \(self.modelName, privacy: .public) は既にロード済み")
            await progress(1.0)
            return
        }

        let modelName = self.modelName
        AppLog.caption.info("prepare 開始: model=\(modelName, privacy: .public)")

        await progress(0.0)

        // 進捗ログのスロットリング: 5% 刻みで 1 回だけログを吐く。
        let lastLoggedPercent = ManagedAtomicInt(value: -1)

        do {
            // Step 1: モデルを明示的にダウンロード (進捗を実時間で取得)。
            //
            // WhisperKit(model:..., download: true) のワンショット init では
            // ダウンロード進捗コールバックが取れず、DL 中は UI が固まって見える
            // (典型的には「5% のまま動かない」症状)。
            // 0.9+ の static `download(variant:progressCallback:)` を使い、
            // 実 DL 進捗を 0.0 → 0.95 にマップして UI に流す。
            AppLog.caption.info("DL 開始: \(modelName, privacy: .public) from argmaxinc/whisperkit-coreml")
            let dlStart = Date()
            let modelFolder = try await WhisperKit.download(
                variant: modelName,
                from: "argmaxinc/whisperkit-coreml"
            ) { dlProgress in
                let fraction = dlProgress.fractionCompleted
                let bytesDone = dlProgress.completedUnitCount
                let bytesTotal = dlProgress.totalUnitCount

                // 5% 刻みでログ
                let percent = Int(fraction * 100)
                let bucket = percent / 5
                if bucket > lastLoggedPercent.value {
                    lastLoggedPercent.value = bucket
                    AppLog.caption.info("DL 進捗 \(percent)% (\(bytesDone)/\(bytesTotal) bytes)")
                }

                // 0.0–0.95 にマップ (ロード/prewarm 用に 0.05 残す)。
                let mapped = max(0.0, min(0.95, fraction * 0.95))
                Task { @MainActor in
                    progress(mapped)
                }
            }
            let dlDuration = Date().timeIntervalSince(dlStart)
            AppLog.caption.info("DL 完了: \(String(format: "%.1f", dlDuration))s, modelFolder=\(modelFolder.path, privacy: .public)")
            try Task.checkCancellation()

            // Step 2: ダウンロード済みフォルダを指定してロード + prewarm。
            // download: false にして再 DL を防ぐ。
            AppLog.caption.info("ロード + prewarm 開始")
            await progress(0.95)
            let loadStart = Date()
            // デバッグ中は WhisperKit 内部ログも見えるよう verbose=true / logLevel=.debug。
            // 静定後 (動作確認終了後) に false / .error に戻す。
            // ANE は長時間連続推論（〜23分超）でハングするため無効化。
            // cpuAndGPU のみで RTF 0.50x（実時間の半分）を確認済み。
            let computeOpts = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU,
                prefillCompute: .cpuOnly
            )
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                computeOptions: computeOpts,
                verbose: true,
                logLevel: .debug,
                prewarm: true,
                load: true,
                download: false
            )
            let pipe = try await WhisperKit(config)
            pipeline = pipe
            await progress(1.0)
            let loadDuration = Date().timeIntervalSince(loadStart)
            AppLog.caption.info("prepare 完了: load=\(String(format: "%.1f", loadDuration))s")
        } catch is CancellationError {
            AppLog.caption.notice("prepare キャンセル")
            throw CaptionEngineError.cancelled
        } catch {
            AppLog.caption.error("prepare 失敗: \(error.localizedDescription, privacy: .public)")
            throw CaptionEngineError.engineUnavailable("WhisperKit init failed: \(error.localizedDescription)")
        }
    }

    /// 5% 刻みログ用の thread-safe ではない簡易カウンタ
    /// (download コールバックは同一スレッドで呼ばれるため race は起きない)
    private final class ManagedAtomicInt {
        var value: Int
        init(value: Int) { self.value = value }
    }

    /// transcribe コールバックのログをスロットルするための保持クラス。
    private final class CallbackThrottle {
        var lastLogged: Date?
    }

    func transcribe(
        url: URL,
        language: String,
        progress: @MainActor @escaping (Double) -> Void,
        onSegments: (@MainActor ([RawTranscriptionSegment]) -> Void)? = nil
    ) async throws -> [RawTranscriptionSegment] {
        AppLog.transcribe.info("transcribe メソッド入口")
        AppLog.transcribe.info("url=\(url.path, privacy: .public)")
        AppLog.transcribe.info("lang=\(language, privacy: .public)")

        guard let pipe = pipeline else {
            AppLog.transcribe.error("パイプライン未準備")
            throw CaptionEngineError.engineUnavailable("モデルが準備されていません。先に prepare を呼んでください。")
        }
        AppLog.transcribe.info("パイプライン取得 OK")

        AppLog.transcribe.info("音声総長取得開始")
        let totalSeconds = await Self.loadDurationSeconds(url: url)
        AppLog.transcribe.info("音声総長: \(String(format: "%.1f", totalSeconds))s")

        // ストリーミング: segmentDiscoveryCallback で確定 segment を逐次通知する。
        // スレッドセーフな累積バッファ。WhisperKit のコールバックは非 MainActor で呼ばれる。
        let streamBuffer = StreamBuffer()
        if onSegments != nil {
            pipe.segmentDiscoveryCallback = { [weak streamBuffer] whisperSegments in
                guard let buf = streamBuffer else { return }
                var newRaw: [RawTranscriptionSegment] = []
                for seg in whisperSegments {
                    let cleanText = Self.stripSpecialTokens(seg.text)
                    guard !cleanText.isEmpty else { continue }
                    let conf = max(0.0, min(1.0, Double(exp(seg.avgLogprob))))
                    let words: [WordTiming]? = seg.words?.compactMap { w in
                        let cleanWord = Self.stripSpecialTokens(w.word)
                        guard !cleanWord.isEmpty else { return nil }
                        return WordTiming(
                            word: cleanWord,
                            startMs: Int(Double(w.start) * 1000),
                            endMs: Int(Double(w.end) * 1000)
                        )
                    }
                    newRaw.append(RawTranscriptionSegment(
                        text: cleanText,
                        startMs: Int(Double(seg.start) * 1000),
                        endMs: Int(Double(seg.end) * 1000),
                        confidence: conf,
                        words: words
                    ))
                }
                guard !newRaw.isEmpty else { return }
                buf.append(newRaw)
                let snapshot = buf.snapshot()
                Task { @MainActor in
                    onSegments?(snapshot)
                }
            }
        }
        defer { pipe.segmentDiscoveryCallback = nil }

        let callback: TranscriptionCallback = { _ in
            return !Task.isCancelled ? nil : true
        }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = (language == "auto") ? nil : language
        // 単語タイムスタンプを有効化。CaptionSegmenter が自然な単語境界で字幕分割する
        // ために必要 (これがないと均等時間配分で発話の真ん中で切れる)。
        options.wordTimestamps = true
        AppLog.transcribe.info("DecodingOptions 構築完了 lang=\(options.language ?? "auto", privacy: .public) wordTimestamps=true")

        // 進捗 polling タスク。
        let progressTask = Task { [weak pipe] in
            var lastLoggedBucket = -1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let fraction = pipe?.progress.fractionCompleted else { continue }
                let percent = Int(fraction * 100)
                let bucket = percent / 5
                if bucket > lastLoggedBucket {
                    lastLoggedBucket = bucket
                    AppLog.transcribe.debug("progress polling: \(percent)%")
                }
                await MainActor.run {
                    progress(min(1.0, max(0.0, fraction)))
                }
            }
        }

        do {
            AppLog.transcribe.info("pipe.transcribe 呼び出し開始")
            let transcribeStart = Date()
            let results: [TranscriptionResult] = try await pipe.transcribe(
                audioPath: url.path,
                decodeOptions: options,
                callback: callback
            )
            progressTask.cancel()
            let transcribeDuration = Date().timeIntervalSince(transcribeStart)
            AppLog.transcribe.info("pipe.transcribe 完了: \(String(format: "%.1f", transcribeDuration))s, results=\(results.count)")
            await MainActor.run { progress(1.0) }
            try Task.checkCancellation()

            var raw: [RawTranscriptionSegment] = []
            for result in results {
                for seg in result.segments {
                    let cleanText = Self.stripSpecialTokens(seg.text)
                    guard !cleanText.isEmpty else { continue }
                    let conf = max(0.0, min(1.0, Double(exp(seg.avgLogprob))))
                    let words: [WordTiming]? = seg.words?.compactMap { w in
                        let cleanWord = Self.stripSpecialTokens(w.word)
                        guard !cleanWord.isEmpty else { return nil }
                        return WordTiming(
                            word: cleanWord,
                            startMs: Int(Double(w.start) * 1000),
                            endMs: Int(Double(w.end) * 1000)
                        )
                    }
                    raw.append(RawTranscriptionSegment(
                        text: cleanText,
                        startMs: Int(Double(seg.start) * 1000),
                        endMs: Int(Double(seg.end) * 1000),
                        confidence: conf,
                        words: words
                    ))
                }
            }
            raw.sort { $0.startMs < $1.startMs }
            AppLog.transcribe.info("transcribe 完了: \(raw.count) segments")
            return raw

        } catch is CancellationError {
            progressTask.cancel()
            AppLog.transcribe.notice("transcribe キャンセル")
            throw CaptionEngineError.cancelled
        } catch {
            progressTask.cancel()
            AppLog.transcribe.error("transcribe 失敗: \(error.localizedDescription, privacy: .public)")
            throw CaptionEngineError.transcriptionFailed("\(error.localizedDescription)")
        }
    }

    // MARK: - Chunk transcription (VAD 経由 / アンサンブル両用)

    /// 短い PCM 音声 (16kHz Float32, mono) を直接認識する。
    /// VAD で切り出した区間や、アンサンブルチェック用の短いリージョンに使う。
    /// prepare() 済みであることが前提。タイムスタンプは呼び出し側が VAD 等から既に持っているので、
    /// ここではテキストのみ返す。
    /// Whisper の入力上限 (30秒 = 480,000 samples @16kHz)。
    /// これを超える入力は分割して処理する。
    private static let maxSamplesPerChunk = 30 * 16_000

    func transcribeSamples(
        samples: [Float],
        sampleRate: Int,
        language: String
    ) async throws -> String {
        guard let pipe = pipeline else {
            throw CaptionEngineError.engineUnavailable("モデルが準備されていません。先に prepare を呼んでください。")
        }

        let inputSamples: [Float]
        if sampleRate != 16_000 {
            AppLog.transcribe.warning("WhisperKit.transcribeSamples: 16kHz でない入力 (\(sampleRate)Hz)。エンジン内部で処理を試行")
            inputSamples = samples
        } else {
            inputSamples = samples
        }

        // 30秒以下ならそのまま、超えたら分割して連結
        if inputSamples.count <= Self.maxSamplesPerChunk {
            return try await transcribeOneChunk(pipe: pipe, samples: inputSamples, language: language)
        }

        // 30秒ごとに分割して順次処理
        var parts: [String] = []
        var offset = 0
        while offset < inputSamples.count {
            try Task.checkCancellation()
            let end = min(offset + Self.maxSamplesPerChunk, inputSamples.count)
            let chunk = Array(inputSamples[offset..<end])
            let text = try await transcribeOneChunk(pipe: pipe, samples: chunk, language: language)
            if !text.isEmpty { parts.append(text) }
            offset = end
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeOneChunk(
        pipe: WhisperKit,
        samples: [Float],
        language: String
    ) async throws -> String {
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = (language == "auto" || language.isEmpty) ? nil : language
        options.wordTimestamps = false

        let callback: TranscriptionCallback = { _ in
            return !Task.isCancelled ? nil : true
        }

        do {
            let results: [TranscriptionResult] = try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: options,
                callback: callback
            )
            try Task.checkCancellation()
            let text = results
                .flatMap { $0.segments }
                .map { Self.stripSpecialTokens($0.text) }
                .joined(separator: " ")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            throw CaptionEngineError.cancelled
        } catch {
            throw CaptionEngineError.transcriptionFailed("\(error.localizedDescription)")
        }
    }

    // MARK: - セグメント付き文字起こし (no-VAD モード用)

    func transcribeSamplesWithSegments(
        samples: [Float],
        sampleRate: Int,
        language: String,
        baseOffsetMs: Int
    ) async throws -> [RawTranscriptionSegment] {
        guard let pipe = pipeline else {
            throw CaptionEngineError.engineUnavailable("モデルが準備されていません。先に prepare を呼んでください。")
        }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = (language == "auto" || language.isEmpty) ? nil : language
        options.wordTimestamps = true

        let callback: TranscriptionCallback = { _ in
            return !Task.isCancelled ? nil : true
        }

        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: callback
        )
        try Task.checkCancellation()

        var segments: [RawTranscriptionSegment] = []
        for result in results {
            for seg in result.segments {
                let cleanText = Self.stripSpecialTokens(seg.text)
                guard !cleanText.isEmpty else { continue }
                let conf = max(0.0, min(1.0, Double(exp(seg.avgLogprob))))
                let words: [WordTiming]? = seg.words?.compactMap { w in
                    let cleanWord = Self.stripSpecialTokens(w.word)
                    guard !cleanWord.isEmpty else { return nil }
                    return WordTiming(
                        word: cleanWord,
                        startMs: baseOffsetMs + Int(Double(w.start) * 1000),
                        endMs: baseOffsetMs + Int(Double(w.end) * 1000)
                    )
                }
                segments.append(RawTranscriptionSegment(
                    text: cleanText,
                    startMs: baseOffsetMs + Int(Double(seg.start) * 1000),
                    endMs: baseOffsetMs + Int(Double(seg.end) * 1000),
                    confidence: conf,
                    words: words
                ))
            }
        }
        return segments
    }

    // MARK: - Language detection (多言語パイプライン用)

    func detectLanguage(
        samples: [Float],
        sampleRate: Int
    ) async throws -> (language: String, langProbs: [String: Float])? {
        guard let pipe = pipeline else {
            throw CaptionEngineError.engineUnavailable("モデルが準備されていません。先に prepare を呼んでください。")
        }
        // WhisperKit の detectLangauge (typo は WhisperKit 側の API 名)
        let result = try await pipe.detectLangauge(audioArray: samples)
        return (language: result.language, langProbs: result.langProbs)
    }

    /// segmentDiscoveryCallback はバックグラウンドスレッドから呼ばれるためスレッドセーフなバッファ。
    private final class StreamBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var segments: [RawTranscriptionSegment] = []

        func append(_ newSegments: [RawTranscriptionSegment]) {
            lock.lock()
            segments.append(contentsOf: newSegments)
            lock.unlock()
        }

        func snapshot() -> [RawTranscriptionSegment] {
            lock.lock()
            let copy = segments
            lock.unlock()
            return copy
        }
    }

    // MARK: - Helpers

    /// Whisper の special token (`<|...|>`) をテキストから除去する。
    /// WhisperKit 0.18 系では segment.text に startoftranscript / 言語 / task /
    /// timestamp 等のトークンがそのまま残るケースがあるため、表示前に剥がす。
    /// 例: "<|startoftranscript|><|ja|><|transcribe|><|0.00|>(拍手)<|11.36|>" → "(拍手)"
    private static func stripSpecialTokens(_ text: String) -> String {
        // `<|` から `|>` までを貪欲ではなく最小マッチで削除する。
        // 改行や空白を挟むこともあるので . は . , [^|]+ は非欲張りで安全。
        let pattern = #"<\|[^|]+\|>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadDurationSeconds(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let d = try await asset.load(.duration)
            let s = d.seconds
            return s.isFinite && s > 0 ? s : 0
        } catch {
            return 0
        }
    }
}
