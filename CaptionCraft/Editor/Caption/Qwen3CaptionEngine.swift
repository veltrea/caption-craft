import AVFoundation
import Foundation
import AudioCommon
import Qwen3ASR

// MARK: - Qwen3CaptionEngine

/// CaptionEngine の Qwen3-ASR 実装 (Alibaba Qwen3 / MLX)。
///
/// 設計メモ:
/// - 52 言語対応、コードスイッチング (混合言語) をネイティブ処理する。
/// - Whisper と異なり、language パラメータは「出力言語」ではなく「ヒント」として機能する。
///   language: nil で自動検出し、音声の言語をそのまま書き起こす (翻訳しない)。
///   これが Whisper の根本的な翻訳問題を解決する。
/// - MLX バックエンドで Apple Silicon の GPU / Neural Engine をネイティブ活用。
/// - モデルは初回 prepare 時に HuggingFace から自動 DL。
///   キャッシュ先: `~/Library/Caches/qwen3-speech/`
///
/// 成熟度: experimental
final class Qwen3CaptionEngine: CaptionEngine {

    /// Qwen3-ASR の期待サンプルレート (16kHz)。
    private let targetSampleRate = 16_000

    private var model: Qwen3ASRModel?

    /// デフォルトモデル ID。0.6B 4bit 量子化版 (高速・省メモリ)。
    /// 精度重視なら 1.7B に切り替え可能。
    private let defaultModelId = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"

    func isAvailable() async -> Bool {
        true
    }

    func prepare(
        progress: @MainActor @escaping (Double) -> Void
    ) async throws {
        if model != nil {
            AppLog.caption.info("Qwen3-ASR: 既にロード済み")
            await progress(1.0)
            return
        }

        AppLog.caption.info("Qwen3-ASR prepare 開始: \(self.defaultModelId, privacy: .public)")
        await progress(0.0)

        do {
            let loaded = try await Qwen3ASRModel.fromPretrained(
                modelId: defaultModelId,
                cacheDir: nil,
                offlineMode: false,
                progressHandler: { fraction, status in
                    AppLog.caption.debug("Qwen3-ASR DL: \(Int(fraction * 100))% \(status, privacy: .public)")
                    let mapped = max(0.0, min(1.0, fraction))
                    Task { @MainActor in
                        progress(mapped)
                    }
                }
            )
            try Task.checkCancellation()

            self.model = loaded
            await progress(1.0)
            AppLog.caption.info("Qwen3-ASR prepare 完了")
        } catch is CancellationError {
            throw CaptionEngineError.cancelled
        } catch {
            AppLog.caption.error("Qwen3-ASR prepare 失敗: \(error.localizedDescription, privacy: .public)")
            throw CaptionEngineError.engineUnavailable("Qwen3-ASR モデルのロードに失敗: \(error.localizedDescription)")
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

        // 音声ファイル全体を 16kHz Float32 PCM として読み込む。
        AppLog.transcribe.info("Qwen3-ASR transcribe: 音声読み込み開始 url=\(url.lastPathComponent, privacy: .public)")
        let samples: [Float]
        do {
            samples = try AudioFileLoader.load(url: url, targetSampleRate: targetSampleRate)
        } catch {
            throw CaptionEngineError.audioLoadFailed("\(error.localizedDescription)")
        }
        let totalSeconds = Double(samples.count) / Double(targetSampleRate)
        AppLog.transcribe.info("Qwen3-ASR: 読み込み完了 \(samples.count) samples (\(String(format: "%.1f", totalSeconds))s)")

        try Task.checkCancellation()

        // Qwen3-ASR は language: nil で言語自動検出。
        // "auto" や空文字の場合も nil にして自動検出を有効にする。
        let langHint: String? = (language == "auto" || language.isEmpty) ? nil : language

        var options = Qwen3DecodingOptions()
        options.language = langHint
        options.repetitionPenalty = 1.3
        options.noRepeatNgramSize = 4

        let text = model.transcribe(
            audio: samples,
            sampleRate: targetSampleRate,
            options: options
        )

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments: [RawTranscriptionSegment]
        if trimmed.isEmpty {
            segments = []
        } else {
            // Qwen3-ASR のこの API はファイル全体を 1 テキストで返す。
            // 後段の VAD + CaptionSegmenter が適切に分割する。
            segments = [RawTranscriptionSegment(
                text: trimmed,
                startMs: 0,
                endMs: Int(totalSeconds * 1000),
                confidence: 1.0
            )]
        }

        await progress(1.0)
        await onSegments?(segments)

        AppLog.transcribe.info("Qwen3-ASR transcribe 完了: \(segments.count) segments")
        return segments
    }

    // MARK: - Chunk transcription (VAD 経由 / アンサンブル両用)

    /// 短い PCM 音声 (典型的には VAD で切り出した 1 区間) を直接認識する。
    /// prepare() が未実行ならここで実行する (lazy init)。
    ///
    /// Qwen3-ASR の最大の強み: language パラメータを渡さなくても正しい言語で書き起こす。
    /// Whisper のように「指定言語に翻訳」することがない。
    func transcribeSamples(
        samples: [Float],
        sampleRate: Int,
        language: String
    ) async throws -> String {
        if model == nil {
            AppLog.caption.info("Qwen3-ASR: lazy load (chunk認識経路)")
            try await prepare { _ in }
        }
        guard let model else {
            throw CaptionEngineError.engineUnavailable("Qwen3-ASR モデルが利用できません")
        }

        // "auto" / "" は nil にして Qwen3-ASR の自動言語検出に任せる。
        // 言語が明示されていればヒントとして渡す (強制ではなくヒント)。
        let langHint: String? = (language == "auto" || language.isEmpty) ? nil : language

        // 繰り返しループ防止: repetitionPenalty + noRepeatNgramSize を設定。
        // 0.6B 4bit 量子化モデルは短いチャンクで繰り返しに陥りやすいため必須。
        var options = Qwen3DecodingOptions()
        options.language = langHint
        options.repetitionPenalty = 1.3
        options.noRepeatNgramSize = 4

        let text = model.transcribe(
            audio: samples,
            sampleRate: sampleRate,
            options: options
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 旧 API 名 (アンサンブルチェック呼び出し元との互換用)。
    func transcribeChunk(samples: [Float], sampleRate: Int) async throws -> String {
        try await transcribeSamples(samples: samples, sampleRate: sampleRate, language: "")
    }
}
