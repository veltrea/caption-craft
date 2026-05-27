import AVFoundation
import Foundation

// MARK: - CaptionEngine

/// 音声ファイルを Whisper などで文字起こしするエンジンの抽象。
/// CaptionTranscriber はこの protocol 経由で実装をスワップ可能にする。
///
/// Phase 1 時点の実装:
/// - `MockCaptionEngine` — 固定 segment を返すテスト/デモ用 (デフォルト)
/// - `WhisperKitCaptionEngine` — 本番用 (FIX_10 後半で実装予定。WhisperKit SPM 依存 + macOS 14 要件)
///
/// 成熟度: experimental (FIX_10 Phase 1)
protocol CaptionEngine: AnyObject {
    /// エンジンが利用可能か。
    func isAvailable() async -> Bool

    /// モデルをロード (必要なら DL)。進捗 0–1 を callback で通知。
    /// 既に読み込み済みの場合は即時 return。
    func prepare(
        progress: @MainActor @escaping (Double) -> Void
    ) async throws

    /// 指定 URL の音声ファイルを文字起こしする。
    /// - Parameters:
    ///   - url: 音声 (mp4/m4a/wav など AVFoundation が開ける形式)
    ///   - language: ISO 639-1 or "auto"
    ///   - progress: 0–1 の進捗コールバック (MainActor 呼び出し)
    ///   - onSegments: 確定した segment がストリーミングで通知されるコールバック (MainActor)。
    ///     呼ばれるたびにその時点で確定済みの全 segment を渡す (差分ではなく累積)。
    ///     nil の場合はストリーミング通知なし。
    /// - Returns: Whisper 生 segment 列 (時間順)
    func transcribe(
        url: URL,
        language: String,
        progress: @MainActor @escaping (Double) -> Void,
        onSegments: (@MainActor ([RawTranscriptionSegment]) -> Void)?
    ) async throws -> [RawTranscriptionSegment]

    /// 短い PCM 音声サンプル (典型的には VAD で切り出した 1 発話区間) をテキスト化する。
    /// タイムスタンプは呼び出し側 (VAD 由来) が持つので、ここではテキストのみ返す。
    ///
    /// - Parameters:
    ///   - samples: Float32 PCM (mono, 16kHz 想定だが内部リサンプリングするエンジンもある)
    ///   - sampleRate: samples のサンプルレート (Hz)
    ///   - language: ISO 639-1 or "auto" or "" (エンジン側で自動検出)
    /// - Returns: 認識テキスト (trim 済み)。空文字を返すこともある (無音と判定された場合等)
    func transcribeSamples(
        samples: [Float],
        sampleRate: Int,
        language: String
    ) async throws -> String

    /// 短い PCM 音声サンプルを文字起こしし、セグメントレベルのタイムスタンプ付きで返す。
    /// no-VAD モード（30秒チャンク→複数字幕リージョン展開）で使用する。
    ///
    /// - Parameters:
    ///   - samples: Float32 PCM (mono, 16kHz)
    ///   - sampleRate: samples のサンプルレート (Hz)
    ///   - language: ISO 639-1 or "auto"
    ///   - baseOffsetMs: チャンクが全体音声の何ms地点から始まるか。
    ///     返すセグメントのタイムスタンプにこのオフセットを加算する。
    /// - Returns: タイムスタンプ付きセグメント列。
    func transcribeSamplesWithSegments(
        samples: [Float],
        sampleRate: Int,
        language: String,
        baseOffsetMs: Int
    ) async throws -> [RawTranscriptionSegment]

    /// 音声サンプルから言語を検出する (多言語パイプライン用)。
    /// - Returns: (言語コード ISO 639-1, 言語ごとの確率)。未対応エンジンは nil を返す。
    func detectLanguage(
        samples: [Float],
        sampleRate: Int
    ) async throws -> (language: String, langProbs: [String: Float])?
}

extension CaptionEngine {
    func transcribeSamplesWithSegments(
        samples: [Float],
        sampleRate: Int,
        language: String,
        baseOffsetMs: Int
    ) async throws -> [RawTranscriptionSegment] {
        // デフォルト: テキストのみ版にフォールバック（セグメント分割なし）
        let text = try await transcribeSamples(samples: samples, sampleRate: sampleRate, language: language)
        let durationMs = Int(Double(samples.count) / Double(sampleRate) * 1000.0)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [RawTranscriptionSegment(
            text: text,
            startMs: baseOffsetMs,
            endMs: baseOffsetMs + durationMs
        )]
    }

    func detectLanguage(samples: [Float], sampleRate: Int) async throws -> (language: String, langProbs: [String: Float])? {
        nil
    }
}

// MARK: - CaptionEngineError

enum CaptionEngineError: LocalizedError {
    case engineUnavailable(String)
    case audioLoadFailed(String)
    case transcriptionFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let r): return "字幕エンジンが利用できません: \(r)"
        case .audioLoadFailed(let r):   return "音声の読み込みに失敗しました: \(r)"
        case .transcriptionFailed(let r): return "文字起こしに失敗しました: \(r)"
        case .cancelled:                return "キャンセルされました"
        }
    }
}

// MARK: - MockCaptionEngine

/// 開発・テスト用のモック実装。
/// 指定音源の長さから等間隔でダミー segment を生成して返す。
/// これにより Whisper 実装なしでも Caption パイプライン全体を UI で動作確認できる。
///
/// 本番 WhisperKit 実装を追加したら、`VideoEditorView` の注入を差し替えるだけで置換可能。
final class MockCaptionEngine: CaptionEngine {

    /// デフォルトの日本語サンプル台詞。長い録画では循環して使う。
    private let sampleTexts: [String] = [
        "こんにちは。今日はデモを始めます。",
        "画面収録ソフトを触ってみましょう。",
        "タイムラインに字幕が表示されました？",
        "手動で文字を修正できます！",
        "最後まで見ていただきありがとうございます。"
    ]

    func isAvailable() async -> Bool {
        true
    }

    func prepare(
        progress: @MainActor @escaping (Double) -> Void
    ) async throws {
        // Mock はロード不要。小さな段階進捗を返して UI の動作を確認可能に。
        for step in stride(from: 0.0, through: 1.0, by: 0.25) {
            try await Task.sleep(nanoseconds: 80_000_000)
            await progress(step)
        }
    }

    func transcribe(
        url: URL,
        language: String,
        progress: @MainActor @escaping (Double) -> Void,
        onSegments: (@MainActor ([RawTranscriptionSegment]) -> Void)? = nil
    ) async throws -> [RawTranscriptionSegment] {
        let durationMs = try await Self.loadDurationMs(url: url)
        try Task.checkCancellation()

        let chunkMs = 3000
        let count = max(1, (durationMs + chunkMs - 1) / chunkMs)

        var segments: [RawTranscriptionSegment] = []
        for i in 0..<count {
            try Task.checkCancellation()
            let start = i * chunkMs
            let end = min(durationMs, start + chunkMs)
            let text = sampleTexts[i % sampleTexts.count]
            segments.append(RawTranscriptionSegment(
                text: text,
                startMs: start,
                endMs: end,
                confidence: 0.85
            ))
            try await Task.sleep(nanoseconds: 40_000_000)
            await progress(Double(i + 1) / Double(count))
            await onSegments?(segments)
        }
        return segments
    }

    func transcribeSamples(
        samples: [Float],
        sampleRate: Int,
        language: String
    ) async throws -> String {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 50_000_000)
        return sampleTexts.randomElement() ?? ""
    }

    // MARK: - Helpers

    /// 音声 / 動画ファイルの長さ (ms) を AVURLAsset で取得する。
    private static func loadDurationMs(url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        do {
            let dur = try await asset.load(.duration)
            let sec = dur.seconds
            if sec.isFinite, sec > 0 { return Int(sec * 1000) }
        } catch {
            throw CaptionEngineError.audioLoadFailed("\(error)")
        }
        // フォールバック: 10 秒。
        return 10_000
    }
}
