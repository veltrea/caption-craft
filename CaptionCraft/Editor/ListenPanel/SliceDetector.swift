import Accelerate
import AudioCommon
import Foundation

/// ループ区間の音声を解析し、無音区間 + リージョン境界からスライスポイントを検出する。
struct SliceDetector {
    static func intent() -> String { """
    役割: 無音区間検出 (vDSP RMS) と CaptionRegion 境界の 2 手法を組み合わせて
          オーディオのスライスポイント (ms) を返す。DAW/MPC 的な操作に使う。
    成熟度: experimental
    依存: Accelerate (vDSP), AudioCommon (AudioFileLoader)
    """ }

    struct Config {
        /// RMS 計算のフレームサイズ (サンプル数)。16kHz で 160 = 10ms。
        var frameSamples: Int = 160
        /// 無音と判定する RMS 閾値 (0〜1)。音声のピーク RMS に対する比率。
        var silenceThreshold: Float = 0.05
        /// 無音が何フレーム続いたらスライスポイントにするか。
        var minSilenceFrames: Int = 8
        /// 近接スライスポイントの統合距離 (ms)。
        var mergeToleranceMs: Int = 50
    }

    /// スライスポイントの種別。
    enum SliceKind: Equatable {
        case silence
        case regionBoundary
        case manual
    }

    struct SlicePoint: Equatable {
        var ms: Int
        let kind: SliceKind
    }

    /// ループ区間のスライスポイントを検出する。
    /// - Parameters:
    ///   - url: 音声/動画ファイル
    ///   - loopStartMs: ループ開始 (ms)
    ///   - loopEndMs: ループ終了 (ms)
    ///   - regionBoundaries: CaptionRegion の startMs/endMs のうちループ区間内のもの
    ///   - config: 検出パラメータ
    /// - Returns: ms 昇順のスライスポイント配列
    static func detect(
        url: URL,
        loopStartMs: Int,
        loopEndMs: Int,
        regionBoundaries: [Int],
        config: Config = Config()
    ) async -> [SlicePoint] {
        let silencePoints = await detectSilenceBoundaries(
            url: url,
            loopStartMs: loopStartMs,
            loopEndMs: loopEndMs,
            config: config
        )

        let regionPoints = regionBoundaries
            .filter { $0 > loopStartMs && $0 < loopEndMs }
            .map { SlicePoint(ms: $0, kind: .regionBoundary) }

        return merge(silencePoints + regionPoints, toleranceMs: config.mergeToleranceMs)
    }

    // MARK: - 無音区間検出 (vDSP RMS)

    private static func detectSilenceBoundaries(
        url: URL,
        loopStartMs: Int,
        loopEndMs: Int,
        config: Config
    ) async -> [SlicePoint] {
        await Task.detached(priority: .userInitiated) {
            do {
                let sampleRate: Int = 16_000
                let samples = try AudioFileLoader.load(url: url, targetSampleRate: sampleRate)
                let startSample = max(0, loopStartMs * sampleRate / 1000)
                let endSample = min(samples.count, loopEndMs * sampleRate / 1000)
                guard endSample > startSample else { return [] }

                let region = Array(samples[startSample..<endSample])
                let frameSize = config.frameSamples
                let frameCount = region.count / frameSize
                guard frameCount > 0 else { return [] }

                // フレームごとの RMS を計算
                var rmsValues = [Float](repeating: 0, count: frameCount)
                for i in 0..<frameCount {
                    let offset = i * frameSize
                    var rms: Float = 0
                    region.withUnsafeBufferPointer { buf in
                        vDSP_rmsqv(buf.baseAddress! + offset, 1, &rms, vDSP_Length(frameSize))
                    }
                    rmsValues[i] = rms
                }

                // ピーク RMS で正規化
                let peakRMS = rmsValues.max() ?? 1.0
                guard peakRMS > 0 else { return [] }
                let threshold = peakRMS * config.silenceThreshold

                // 無音区間を検出: 閾値以下が minSilenceFrames 以上続く区間
                var points: [SlicePoint] = []
                var silenceStart: Int?
                for i in 0..<frameCount {
                    if rmsValues[i] < threshold {
                        if silenceStart == nil { silenceStart = i }
                    } else {
                        if let start = silenceStart {
                            let length = i - start
                            if length >= config.minSilenceFrames {
                                // 無音区間の中央をスライスポイントにする
                                let centerFrame = start + length / 2
                                let ms = loopStartMs + centerFrame * frameSize * 1000 / sampleRate
                                points.append(SlicePoint(ms: ms, kind: .silence))
                            }
                        }
                        silenceStart = nil
                    }
                }

                return points
            } catch {
                return []
            }
        }.value
    }

    // MARK: - マージ

    /// 近接ポイントを統合し、ms 昇順でソートして返す。
    private static func merge(_ points: [SlicePoint], toleranceMs: Int) -> [SlicePoint] {
        let sorted = points.sorted { $0.ms < $1.ms }
        var result: [SlicePoint] = []
        for point in sorted {
            if let last = result.last, abs(point.ms - last.ms) < toleranceMs {
                // 近接: regionBoundary を優先
                if point.kind == .regionBoundary && last.kind != .regionBoundary {
                    result[result.count - 1] = point
                }
            } else {
                result.append(point)
            }
        }
        return result
    }
}
