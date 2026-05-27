import AVFoundation
import Foundation

/// Signalsmith Stretch を使ったオフライン音声タイムストレッチ。
/// 動画ファイルから音声を抽出し、指定倍率でストレッチした WAV を一時ファイルに書き出す。
/// 再生パイプライン (AVPlayer) には一切触れない安全な設計。
final class AudioStretchRenderer {

    static func intent() -> String { """
    役割: Signalsmith Stretch エンジンで音声をオフラインタイムストレッチする。
    成熟度: experimental
    設計: AVPlayer の再生パイプラインとは完全に独立。
          入力 URL → 音声抽出 → Signalsmith 処理 → WAV 出力。
          呼び出し元は出力 WAV を AVPlayer にロードし直す。
    依存: SignalsmithBridge.h (C API)
    注意: メインスレッドで呼ばないこと。処理は数秒かかる。
    """ }

    struct Progress {
        let fractionCompleted: Double
    }

    enum RendererError: Error, LocalizedError {
        case noAudioTrack
        case readFailed(String)
        case writeFailed(String)
        case stretchFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:        return "音声トラックが見つからない"
            case .readFailed(let m):   return "音声読み込み失敗: \(m)"
            case .writeFailed(let m):  return "WAV 書き出し失敗: \(m)"
            case .stretchFailed(let m): return "ストレッチ失敗: \(m)"
            }
        }
    }

    // MARK: - Public

    /// 動画/音声ファイルの指定範囲を抽出し、timeRatio 倍に伸縮した WAV を返す。
    /// - Parameters:
    ///   - sourceURL: 元の動画/音声ファイル
    ///   - timeRatio: 伸縮率。2.0 = 2倍に伸ばす (半分の速度)、1.0 = 等速
    ///   - startTime: 抽出開始時刻 (秒)
    ///   - endTime: 抽出終了時刻 (秒)
    ///   - onProgress: 進捗コールバック (0.0〜1.0)
    /// - Returns: ストレッチ済み WAV ファイルの URL (一時ディレクトリ)
    static func render(
        sourceURL: URL,
        timeRatio: Double,
        startTime: Double,
        endTime: Double,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.first != nil else {
            throw RendererError.noAudioTrack
        }

        let (samples, sampleRate, channels) = try await extractAudio(
            asset: asset,
            track: audioTracks.first!,
            startTime: startTime,
            endTime: endTime,
            onProgress: { frac in
                onProgress?(Progress(fractionCompleted: frac * 0.3))
            }
        )

        onProgress?(Progress(fractionCompleted: 0.3))

        let stretched = try stretchWithSignalsmith(
            samples: samples,
            sampleRate: Int(sampleRate),
            channels: channels,
            timeRatio: timeRatio
        )

        onProgress?(Progress(fractionCompleted: 0.9))

        let outputURL = try writeWAV(
            samples: stretched,
            sampleRate: Int(sampleRate),
            channels: channels
        )

        onProgress?(Progress(fractionCompleted: 1.0))
        return outputURL
    }

    // MARK: - Signalsmith ストレッチ

    private static func stretchWithSignalsmith(
        samples: [[Float]],
        sampleRate: Int,
        channels: Int,
        timeRatio: Double
    ) throws -> [[Float]] {
        let inputFrames = samples[0].count
        guard inputFrames > 0 else {
            throw RendererError.stretchFailed("入力サンプルが空")
        }

        let outputFrames = Int(Double(inputFrames) * timeRatio) + 1024

        guard let stretcher = ss_create(Int32(sampleRate), Int32(channels)) else {
            throw RendererError.stretchFailed("Signalsmith Stretch の初期化に失敗")
        }
        defer { ss_destroy(stretcher) }

        // 入力ポインタ配列を構築 (non-interleaved)
        var inputArrays = samples
        let inputPtrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: channels)
        defer { inputPtrs.deallocate() }

        for ch in 0..<channels {
            inputArrays[ch].withUnsafeBufferPointer { buf in
                inputPtrs[ch] = buf.baseAddress
            }
        }

        // 出力バッファを確保
        var outputArrays: [[Float]] = (0..<channels).map { _ in
            [Float](repeating: 0, count: outputFrames)
        }
        let outputPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        defer { outputPtrs.deallocate() }

        for ch in 0..<channels {
            outputArrays[ch].withUnsafeMutableBufferPointer { buf in
                outputPtrs[ch] = buf.baseAddress
            }
        }

        let actualOut = ss_stretch_offline(
            stretcher,
            inputPtrs,
            Int32(inputFrames),
            outputPtrs,
            Int32(outputFrames),
            timeRatio,
            Int32(channels)
        )

        // 実際の出力フレーム数にトリム
        let trimmedCount = Int(actualOut)
        for ch in 0..<channels {
            if trimmedCount < outputArrays[ch].count {
                outputArrays[ch].removeSubrange(trimmedCount...)
            }
        }

        return outputArrays
    }

    // MARK: - 音声抽出

    private static func extractAudio(
        asset: AVURLAsset,
        track: AVAssetTrack,
        startTime: Double,
        endTime: Double,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (samples: [[Float]], sampleRate: Double, channels: Int) {
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2
        ]

        let reader = try AVAssetReader(asset: asset)
        let startCMTime = CMTime(seconds: startTime, preferredTimescale: 44100)
        let durationCMTime = CMTime(seconds: endTime - startTime, preferredTimescale: 44100)
        reader.timeRange = CMTimeRange(start: startCMTime, duration: durationCMTime)

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            throw RendererError.readFailed(reader.error?.localizedDescription ?? "不明なエラー")
        }

        let channels = 2
        let sampleRate = 44100.0
        var allSamples: [[Float]] = Array(repeating: [], count: channels)

        let rangeDuration = endTime - startTime
        let totalFrames = max(1, Int(rangeDuration * sampleRate))

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { rawBuf in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawBuf.baseAddress!)
            }

            // non-interleaved: CMBlockBuffer は [ch0 全フレーム][ch1 全フレーム] の並び
            let framesPerChannel = CMSampleBufferGetNumSamples(sampleBuffer)
            let totalFloats = length / MemoryLayout<Float>.size
            let expectedFloats = framesPerChannel * channels
            if totalFloats == expectedFloats {
                data.withUnsafeBytes { rawBuf in
                    let floatPtr = rawBuf.bindMemory(to: Float.self)
                    for ch in 0..<channels {
                        let start = ch * framesPerChannel
                        let end = start + framesPerChannel
                        if end <= floatPtr.count {
                            allSamples[ch].append(contentsOf: floatPtr[start..<end])
                        }
                    }
                }
            }

            let readSoFar = allSamples[0].count
            onProgress?(min(1.0, Double(readSoFar) / Double(totalFrames)))
        }

        if allSamples[0].isEmpty {
            throw RendererError.readFailed("音声サンプルが空")
        }

        return (allSamples, sampleRate, channels)
    }

    // MARK: - WAV 書き出し

    private static func writeWAV(
        samples: [[Float]],
        sampleRate: Int,
        channels: Int
    ) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "ss_stretched_\(UUID().uuidString).wav"
        let outputURL = tempDir.appendingPathComponent(fileName)

        let frameCount = samples[0].count
        guard frameCount > 0 else {
            throw RendererError.writeFailed("出力サンプルが空")
        }

        var interleaved = [Float](repeating: 0, count: frameCount * channels)
        for frame in 0..<frameCount {
            for ch in 0..<channels {
                interleaved[frame * channels + ch] = samples[ch][frame]
            }
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw RendererError.writeFailed("PCM バッファ作成失敗")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let dst = buffer.floatChannelData![0]
        interleaved.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: frameCount * channels)
        }

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )
        try file.write(from: buffer)

        return outputURL
    }
}
