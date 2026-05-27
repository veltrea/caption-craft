import AVFoundation
import Foundation
import AudioCommon
import ParakeetASR

// MARK: - ParakeetCaptionEngine

/// CaptionEngine の Parakeet TDT 実装 (NVIDIA FastConformer + TDT decoder)。
///
/// 設計メモ:
/// - Whisper (encoder-decoder Transformer) と完全に違うアーキテクチャの ASR モデル。
///   アンサンブルとして組み合わせる意義がある。
/// - 25 欧州言語対応 (英仏独伊西露蘭等)。日本語は非対応。
/// - CoreML + Neural Engine ネイティブで WhisperKit より高速。
/// - モデルは初回 prepare 時に HuggingFace から自動 DL (~600MB INT8 量子化版)。
///   キャッシュ先: `~/Library/Caches/...` (HuggingFaceDownloader が管理)
///
/// 制約:
/// - encoder の max mel length が 3000 = 約 30 秒。
///   長尺音声は自前で 30 秒チャンクに分割して逐次認識し、結果を結合する。
/// - ParakeetASR の戻り値はテキストのみで単語タイムスタンプは持たない。
///   そのため**1チャンク = 1 RawTranscriptionSegment** として、チャンク境界が
///   字幕の最小粒度となる。後段の CaptionSegmenter が無音閾値で再分割する。
///
/// 成熟度: experimental
final class ParakeetCaptionEngine: CaptionEngine {

    /// 1チャンクの最大秒数。encoder 上限 30s より少し短くマージンを取る。
    private let chunkSeconds: Double = 28.0

    /// Parakeet の期待サンプルレート (16kHz)。
    private let targetSampleRate = 16_000

    private var model: ParakeetASRModel?

    func isAvailable() async -> Bool {
        true
    }

    func prepare(
        progress: @MainActor @escaping (Double) -> Void
    ) async throws {
        if model != nil {
            AppLog.caption.info("Parakeet: 既にロード済み")
            await progress(1.0)
            return
        }

        AppLog.caption.info("Parakeet prepare 開始: \(ParakeetASRModel.defaultModelId, privacy: .public)")
        await progress(0.0)

        do {
            let loaded = try await ParakeetASRModel.fromPretrained(
                modelId: nil,
                cacheDir: nil,
                offlineMode: false,
                progressHandler: { fraction, status in
                    AppLog.caption.debug("Parakeet DL: \(Int(fraction * 100))% \(status, privacy: .public)")
                    let mapped = max(0.0, min(0.95, fraction * 0.95))
                    Task { @MainActor in
                        progress(mapped)
                    }
                }
            )
            try Task.checkCancellation()

            AppLog.caption.info("Parakeet warmUp 開始 (compute units: \(String(describing: loaded.encoderComputeUnits), privacy: .public))")
            try loaded.warmUp()
            self.model = loaded
            await progress(1.0)
            AppLog.caption.info("Parakeet prepare 完了")
        } catch is CancellationError {
            throw CaptionEngineError.cancelled
        } catch {
            AppLog.caption.error("Parakeet prepare 失敗: \(error.localizedDescription, privacy: .public)")
            throw CaptionEngineError.engineUnavailable("Parakeet モデルのロードに失敗: \(error.localizedDescription)")
        }
    }

    func transcribe(
        url: URL,
        language: String,
        progress: @MainActor @escaping (Double) -> Void,
        onSegments: (@MainActor ([RawTranscriptionSegment]) -> Void)? = nil
    ) async throws -> [RawTranscriptionSegment] {
        guard let model = self.model else {
            throw CaptionEngineError.engineUnavailable("モデルが準備されていません。先に prepare を呼んでください。")
        }

        // Step 1: 音声ファイル全体を 16kHz Float32 PCM として読み込む。
        // AudioFileLoader が AVFoundation 経由で動画/音声から音声トラックを抽出してくれる。
        AppLog.transcribe.info("Parakeet transcribe: 音声読み込み開始 url=\(url.lastPathComponent, privacy: .public)")
        let loadStart = Date()
        let samples: [Float]
        do {
            samples = try AudioFileLoader.load(url: url, targetSampleRate: targetSampleRate)
        } catch {
            throw CaptionEngineError.audioLoadFailed("\(error.localizedDescription)")
        }
        let loadDuration = Date().timeIntervalSince(loadStart)
        let totalSeconds = Double(samples.count) / Double(targetSampleRate)
        AppLog.transcribe.info("Parakeet: 読み込み完了 \(samples.count) samples (\(String(format: "%.1f", totalSeconds))s) in \(String(format: "%.1f", loadDuration))s")

        try Task.checkCancellation()

        // Step 2: 30 秒チャンクに分割
        let chunkSamples = Int(chunkSeconds * Double(targetSampleRate))
        let chunkCount = max(1, (samples.count + chunkSamples - 1) / chunkSamples)
        AppLog.transcribe.info("Parakeet: \(chunkCount) チャンクに分割 (chunkSize=\(chunkSamples) samples)")

        var allSegments: [RawTranscriptionSegment] = []

        // Step 3: 各チャンクを逐次認識
        for chunkIndex in 0..<chunkCount {
            try Task.checkCancellation()

            let chunkStartSample = chunkIndex * chunkSamples
            let chunkEndSample = min(samples.count, chunkStartSample + chunkSamples)
            let chunk = Array(samples[chunkStartSample..<chunkEndSample])
            let chunkStartMs = Int(Double(chunkStartSample) / Double(targetSampleRate) * 1000)
            let chunkEndMs = Int(Double(chunkEndSample) / Double(targetSampleRate) * 1000)

            AppLog.transcribe.debug("Parakeet chunk \(chunkIndex + 1)/\(chunkCount): \(chunkStartMs)ms - \(chunkEndMs)ms")
            let chunkStart = Date()
            let text: String
            do {
                text = try model.transcribeAudio(chunk, sampleRate: targetSampleRate, language: nil)
            } catch {
                AppLog.transcribe.error("Parakeet chunk \(chunkIndex) 失敗: \(error.localizedDescription, privacy: .public)")
                throw CaptionEngineError.transcriptionFailed("\(error.localizedDescription)")
            }
            let chunkElapsed = Date().timeIntervalSince(chunkStart)
            AppLog.transcribe.debug("Parakeet chunk \(chunkIndex + 1) 完了 (\(String(format: "%.2f", chunkElapsed))s): \"\(text.prefix(60), privacy: .public)\"")

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                allSegments.append(RawTranscriptionSegment(
                    text: trimmed,
                    startMs: chunkStartMs,
                    endMs: chunkEndMs,
                    confidence: Double(model.lastConfidence)
                ))
            }

            // 進捗・ストリーミング通知
            let fraction = Double(chunkIndex + 1) / Double(chunkCount)
            await MainActor.run {
                progress(fraction)
                onSegments?(allSegments)
            }
        }

        AppLog.transcribe.info("Parakeet transcribe 完了: \(allSegments.count) segments")
        return allSegments
    }

    // MARK: - Chunk transcription (VAD 経由 / アンサンブル両用)

    /// 短い PCM 音声 (典型的には VAD で切り出した 1 区間) を直接認識する。
    /// 30 秒以下を想定。長い場合は呼び出し側で事前分割すること。
    /// prepare() が未実行ならここで実行する (lazy init)。
    func transcribeSamples(
        samples: [Float],
        sampleRate: Int,
        language: String
    ) async throws -> String {
        if model == nil {
            AppLog.caption.info("Parakeet: lazy load (chunk認識経路)")
            try await prepare { _ in }
        }
        guard let model else {
            throw CaptionEngineError.engineUnavailable("Parakeet モデルが利用できません")
        }
        do {
            // Parakeet は 25 欧州言語のみ。"auto" / "" は内部の言語自動検出に任せる。
            let langHint: String? = (language == "auto" || language.isEmpty) ? nil : language
            return try model.transcribeAudio(samples, sampleRate: sampleRate, language: langHint)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw CaptionEngineError.transcriptionFailed("\(error.localizedDescription)")
        }
    }

    /// 旧 API 名 (アンサンブルチェック呼び出し元との互換用)。新規呼び出しは transcribeSamples を使う。
    func transcribeChunk(samples: [Float], sampleRate: Int) async throws -> String {
        try await transcribeSamples(samples: samples, sampleRate: sampleRate, language: "")
    }
}
