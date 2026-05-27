import AVFoundation
import Foundation

// MARK: - WaveformData

/// 波形描画用のダウンサンプル済み peak 配列。
///
/// 成熟度: experimental
///
/// 設計メモ:
/// - peaks は 0.0–1.0 に正規化済み (元音声の最大絶対値で割った値)
/// - peaks.count = ダウンサンプル後の bin 数 (例: 4000 個)
/// - 各 bin の幅 (ms) = durationMs / peaks.count
struct WaveformData: Equatable {
    /// 0.0–1.0 で正規化された peak 値の配列。
    let peaks: [Float]
    /// 元音声の長さ (ms)。
    let durationMs: Int
    /// 抽出完了なら totalBinCount == peaks.count。進行中は totalBinCount > peaks.count。
    let totalBinCount: Int
    /// 正規化が暫定か確定か。
    let isComplete: Bool

    init(peaks: [Float], durationMs: Int, totalBinCount: Int? = nil, isComplete: Bool = true) {
        self.peaks = peaks
        self.durationMs = durationMs
        self.totalBinCount = totalBinCount ?? peaks.count
        self.isComplete = isComplete
    }

    /// 指定 ms 位置に対応する peak の index を返す。
    /// 0 <= index < peaks.count。範囲外は nil。
    func peakIndex(forMs ms: Int) -> Int? {
        guard durationMs > 0, !peaks.isEmpty else { return nil }
        let ratio = Double(ms) / Double(durationMs)
        let idx = Int(ratio * Double(peaks.count))
        return min(max(0, idx), peaks.count - 1)
    }
}

// MARK: - WaveformExtractor

/// 動画/音声ファイルから波形 peak 配列を抽出する純粋ロジック。
///
/// 成熟度: experimental
///
/// 将来 `WaveformKit` SPM パッケージとして切り出す候補 (docs/GOALS.md §4)。
/// 現状プロジェクトソースディレクトリ内に配置しているが、AVFoundation 以外の
/// 依存は持たないため切り出し可能。
enum WaveformExtractor {

    static func intent() -> String {
        """
        役割: AVAsset の音声トラックを PCM Float32 mono 16kHz で読み込み、
              指定された bin 数にダウンサンプリングして peak (絶対値の max) 配列を返す。
              extractProgressive() はチャンク単位で暫定正規化した部分データを yield し、
              UI がウィンドウを開いた直後から波形を表示できるようにする。
        成熟度: experimental
        依存: AVFoundation のみ (UI / SwiftUI 非依存)
        変更時の注意: メモリ効率のため逐次的に bin に集約する。
                     全サンプルを保持しないこと (1 時間動画で 230MB+ になる)。
        """
    }

    /// 動画/音声ファイルから波形 peak 配列を抽出する。
    ///
    /// - Parameters:
    ///   - url: 動画 / 音声ファイル
    ///   - targetSampleCount: 出力 peak 配列のサイズ最小値 (動画長から動的に増やす)
    /// - Returns: 正規化済み peaks + durationMs
    ///
    /// 解像度設計:
    /// - 100 peaks/sec (= 1 peak ≒ 10ms) を目標にする (字幕の音節単位編集に十分)
    /// - 上限 80,000 peaks (メモリ ~320KB、長尺動画でも処理時間が膨らみすぎない)
    /// - 引数の `targetSampleCount` を下限としてクランプ
    /// - 例: 30 分動画 → 80,000 peaks (1 peak ≒ 22.5ms)
    /// - 例: 1 時間動画 → 80,000 peaks (1 peak ≒ 45ms)
    /// - 例: 5 分動画 → 30,000 peaks (1 peak = 10ms)
    /// - 例: 10 秒動画 → 4,000 peaks (1 peak = 2.5ms、下限優先)
    static func extract(
        url: URL,
        targetSampleCount: Int = 4000
    ) async throws -> WaveformData {
        let asset = AVURLAsset(url: url)

        // 音声長を取得
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw WaveformError.noAudio("durationSeconds invalid: \(durationSeconds)")
        }

        // 動画長に応じた効率的な解像度を計算
        let effectiveTargetCount = max(
            targetSampleCount,
            min(80_000, Int(durationSeconds * 100))
        )

        // 音声トラック取得
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw WaveformError.noAudio("動画に音声トラックがありません")
        }

        // AVAssetReader を構築 (PCM Float32 mono 16kHz)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16000,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)

        guard reader.startReading() else {
            throw WaveformError.readerFailed(
                reader.error?.localizedDescription ?? "AVAssetReader.startReading 失敗"
            )
        }

        // 期待される総サンプル数とビンサイズ (effectiveTargetCount で計算)
        let totalSamples = Int(durationSeconds * 16000)
        let samplesPerBin = max(1, totalSamples / effectiveTargetCount)

        var peaks: [Float] = []
        peaks.reserveCapacity(effectiveTargetCount)
        var currentBinPeak: Float = 0
        var samplesInCurrentBin: Int = 0

        // sample buffer を逐次読みながら bin 集約
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard let dataPointer else { continue }

            let sampleCount = totalLength / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { ptr in
                for i in 0..<sampleCount {
                    let v = abs(ptr[i])
                    if v > currentBinPeak { currentBinPeak = v }
                    samplesInCurrentBin += 1

                    if samplesInCurrentBin >= samplesPerBin {
                        peaks.append(currentBinPeak)
                        currentBinPeak = 0
                        samplesInCurrentBin = 0
                    }
                }
            }
        }

        // 最後の bin の取りこぼし
        if samplesInCurrentBin > 0 {
            peaks.append(currentBinPeak)
        }

        if reader.status == .failed {
            throw WaveformError.readerFailed(
                reader.error?.localizedDescription ?? "AVAssetReader.status == .failed"
            )
        }

        // 正規化 (0.0–1.0 にスケール)
        if let maxPeak = peaks.max(), maxPeak > 0 {
            let inv = 1.0 / maxPeak
            peaks = peaks.map { $0 * inv }
        }

        return WaveformData(
            peaks: peaks,
            durationMs: Int(durationSeconds * 1000)
        )
    }

    // MARK: - Progressive extraction

    struct ProgressiveChunk {
        let peaks: [Float]
        let durationMs: Int
        let totalBinCount: Int
        let runningMax: Float
        let isComplete: Bool
    }

    /// チャンク単位で波形データを yield するストリーム版。
    /// firstEmitCount bins が溜まった瞬間に最初の yield を行い、以降は subsequentInterval ごと。
    /// firstEmitCount は画面幅（px）と同じにすれば、ウィンドウが埋まった瞬間に描画が始まる。
    /// 最終チャンクは isComplete = true で全 peaks を含む（確定正規化済み）。
    static func extractProgressive(
        url: URL,
        targetSampleCount: Int = 4000,
        firstEmitCount: Int = 800,
        subsequentInterval: Int = 4000
    ) -> AsyncThrowingStream<ProgressiveChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration)
                    let durationSeconds = duration.seconds
                    guard durationSeconds.isFinite, durationSeconds > 0 else {
                        throw WaveformError.noAudio("durationSeconds invalid: \(durationSeconds)")
                    }

                    let effectiveTargetCount = max(
                        targetSampleCount,
                        min(80_000, Int(durationSeconds * 100))
                    )

                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    guard let track = tracks.first else {
                        throw WaveformError.noAudio("動画に音声トラックがありません")
                    }

                    let reader = try AVAssetReader(asset: asset)
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatLinearPCM),
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                        AVNumberOfChannelsKey: 1,
                        AVSampleRateKey: 16000,
                    ]
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                    reader.add(output)

                    guard reader.startReading() else {
                        throw WaveformError.readerFailed(
                            reader.error?.localizedDescription ?? "AVAssetReader.startReading 失敗"
                        )
                    }

                    let totalSamples = Int(durationSeconds * 16000)
                    let samplesPerBin = max(1, totalSamples / effectiveTargetCount)
                    let durationMs = Int(durationSeconds * 1000)

                    var rawPeaks: [Float] = []
                    rawPeaks.reserveCapacity(effectiveTargetCount)
                    var currentBinPeak: Float = 0
                    var samplesInCurrentBin: Int = 0
                    var runningMax: Float = 0
                    var lastEmitCount: Int = 0
                    var didFirstEmit = false

                    while let sampleBuffer = output.copyNextSampleBuffer() {
                        try Task.checkCancellation()
                        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                            continue
                        }

                        var totalLength = 0
                        var dataPointer: UnsafeMutablePointer<Int8>? = nil
                        CMBlockBufferGetDataPointer(
                            blockBuffer,
                            atOffset: 0,
                            lengthAtOffsetOut: nil,
                            totalLengthOut: &totalLength,
                            dataPointerOut: &dataPointer
                        )
                        guard let dataPointer else { continue }

                        let sampleCount = totalLength / MemoryLayout<Float>.size
                        dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { ptr in
                            for i in 0..<sampleCount {
                                let v = abs(ptr[i])
                                if v > currentBinPeak { currentBinPeak = v }
                                samplesInCurrentBin += 1

                                if samplesInCurrentBin >= samplesPerBin {
                                    rawPeaks.append(currentBinPeak)
                                    if currentBinPeak > runningMax { runningMax = currentBinPeak }
                                    currentBinPeak = 0
                                    samplesInCurrentBin = 0
                                }
                            }
                        }

                        // 最初の emit: 画面幅分の bin が溜まった瞬間（最速で画面を埋める）
                        // 以降: subsequentInterval ごと
                        let threshold = didFirstEmit ? subsequentInterval : firstEmitCount
                        if rawPeaks.count - lastEmitCount >= threshold {
                            let normalized = Self.normalize(rawPeaks, maxValue: runningMax)
                            continuation.yield(ProgressiveChunk(
                                peaks: normalized,
                                durationMs: durationMs,
                                totalBinCount: effectiveTargetCount,
                                runningMax: runningMax,
                                isComplete: false
                            ))
                            lastEmitCount = rawPeaks.count
                            didFirstEmit = true
                        }
                    }

                    if samplesInCurrentBin > 0 {
                        rawPeaks.append(currentBinPeak)
                        if currentBinPeak > runningMax { runningMax = currentBinPeak }
                    }

                    if reader.status == .failed {
                        throw WaveformError.readerFailed(
                            reader.error?.localizedDescription ?? "AVAssetReader.status == .failed"
                        )
                    }

                    // 確定正規化
                    let finalPeaks = Self.normalize(rawPeaks, maxValue: runningMax)
                    continuation.yield(ProgressiveChunk(
                        peaks: finalPeaks,
                        durationMs: durationMs,
                        totalBinCount: finalPeaks.count,
                        runningMax: runningMax,
                        isComplete: true
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func normalize(_ peaks: [Float], maxValue: Float) -> [Float] {
        guard maxValue > 0 else { return peaks }
        let inv = 1.0 / maxValue
        return peaks.map { $0 * inv }
    }
}

// MARK: - WaveformError

enum WaveformError: LocalizedError {
    case noAudio(String)
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio(let m):       return "音声トラックなし: \(m)"
        case .readerFailed(let m):  return "波形抽出失敗: \(m)"
        }
    }
}

// MARK: - WaveformService

/// 波形抽出を ObservableObject として駆動するサービス。
/// VideoEditorView から StateObject で保持し、動画ロード時に extract を呼ぶ。
/// プログレッシブ抽出により、最初の ~1000 bins が揃った時点で波形表示を開始する。
///
/// 成熟度: experimental
@MainActor
final class WaveformService: ObservableObject {

    @Published private(set) var waveform: WaveformData?
    @Published private(set) var isExtracting: Bool = false
    @Published private(set) var error: String?

    /// 波形表示領域の幅 (px)。TimelineView の GeometryReader から設定する。
    /// 最初の emit 閾値の計算に使う（この幅分の bin が溜まれば画面が埋まる）。
    var visibleWidth: CGFloat = 800

    private var currentTask: Task<Void, Never>?
    private var lastExtractedURL: URL?

    /// 指定 URL の波形を抽出する。同じ URL に対して再度呼ばれた場合はスキップ。
    /// プログレッシブ: visibleWidth 分の bin が揃った瞬間に画面を埋め、残りはバックグラウンドで継続。
    func extract(url: URL, targetSampleCount: Int = 4000) {
        if lastExtractedURL == url, waveform != nil { return }

        currentTask?.cancel()
        isExtracting = true
        error = nil
        waveform = nil

        let firstEmit = max(200, Int(visibleWidth))
        AppLog.playback.info("波形抽出開始(progressive, firstEmit=\(firstEmit)): \(url.lastPathComponent, privacy: .public)")
        let startedAt = Date()

        currentTask = Task { [weak self] in
            do {
                let stream = WaveformExtractor.extractProgressive(
                    url: url,
                    targetSampleCount: targetSampleCount,
                    firstEmitCount: firstEmit
                )
                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self else { return }
                        self.waveform = WaveformData(
                            peaks: chunk.peaks,
                            durationMs: chunk.durationMs,
                            totalBinCount: chunk.totalBinCount,
                            isComplete: chunk.isComplete
                        )
                        if chunk.isComplete {
                            self.isExtracting = false
                            self.lastExtractedURL = url
                            let elapsed = Date().timeIntervalSince(startedAt)
                            AppLog.playback.info("波形抽出完了: \(chunk.peaks.count) bins, \(String(format: "%.1f", elapsed))s")
                        }
                    }
                }
            } catch is CancellationError {
                AppLog.playback.notice("波形抽出キャンセル")
            } catch {
                AppLog.playback.error("波形抽出失敗: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    guard let self else { return }
                    self.error = error.localizedDescription
                    self.isExtracting = false
                }
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isExtracting = false
    }
}
