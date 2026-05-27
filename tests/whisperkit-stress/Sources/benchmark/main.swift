import Foundation
import WhisperKit
import AVFoundation

// ANE有効 vs CPU+GPU のみ ベンチマーク
// ブログ記事用の比較データを生成する。
// ANEがクラッシュしない長さの音声で、純粋な速度差を計測する。

struct BenchmarkResult {
    let file: String
    let durationSec: Double
    let mode: String
    let elapsedSec: Double
    let segmentCount: Int
    let rtf: Double
}

func getDuration(path: String) async throws -> Double {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let duration = try await asset.load(.duration)
    return CMTimeGetSeconds(duration)
}

func runBenchmark(audioPath: String, mode: String, computeOpts: ModelComputeOptions) async throws -> BenchmarkResult {
    let fileName = (audioPath as NSString).lastPathComponent
    let durationSec = try await getDuration(path: audioPath)

    print("  [\(mode)] 初期化中…")
    let pipe = try await WhisperKit(
        model: "openai_whisper-large-v3",
        computeOptions: computeOpts,
        verbose: false,
        logLevel: .error
    )

    var options = DecodingOptions()
    options.task = .transcribe
    options.language = "ja"
    options.wordTimestamps = true

    print("  [\(mode)] transcribe 開始 (\(String(format: "%.1f", durationSec / 60))分)…")
    let start = Date()
    let results = try await pipe.transcribe(
        audioPath: audioPath,
        decodeOptions: options
    )
    let elapsed = Date().timeIntervalSince(start)
    let segments = results.flatMap { $0.segments }
    let rtf = elapsed / durationSec

    print("  [\(mode)] 完了: \(String(format: "%.1f", elapsed))s, セグメント \(segments.count)件, RTF \(String(format: "%.3f", rtf))x")

    return BenchmarkResult(
        file: fileName,
        durationSec: durationSec,
        mode: mode,
        elapsedSec: elapsed,
        segmentCount: segments.count,
        rtf: rtf
    )
}

func main() async throws {
    // ANEがクラッシュしない長さの動画のみ使用
    let cacheDir = NSString("~/Library/Application Support/CaptionCraft/ytcache").expandingTildeInPath
    let shortFiles = ["f-5YMLJSqQ8.mp4", "inDZdBr7TVQ.mp4"]  // 15分、13分

    let testFiles = shortFiles.map { "\(cacheDir)/\($0)" }.filter {
        FileManager.default.fileExists(atPath: $0)
    }

    guard !testFiles.isEmpty else {
        print("ERROR: テストファイルが見つかりません")
        Foundation.exit(1)
    }

    let aneOpts = ModelComputeOptions()  // デフォルト = ANE含む
    let cpuGpuOpts = ModelComputeOptions(
        melCompute: .cpuAndGPU,
        audioEncoderCompute: .cpuAndGPU,
        textDecoderCompute: .cpuAndGPU,
        prefillCompute: .cpuOnly
    )

    var allResults: [BenchmarkResult] = []

    print("=== WhisperKit ANE ベンチマーク ===")
    print("モデル: openai_whisper-large-v3")
    print("")

    for path in testFiles {
        let name = (path as NSString).lastPathComponent
        let dur = try await getDuration(path: path)
        print("--- \(name) (\(String(format: "%.1f", dur / 60))分) ---")

        // ANE有効（デフォルト）
        let aneResult = try await runBenchmark(
            audioPath: path, mode: "ANE有効", computeOpts: aneOpts
        )
        allResults.append(aneResult)

        // CPU+GPUのみ
        let cpuResult = try await runBenchmark(
            audioPath: path, mode: "CPU+GPU", computeOpts: cpuGpuOpts
        )
        allResults.append(cpuResult)

        print("")
    }

    // 結果サマリー（Markdown テーブル）
    print("=== 結果サマリー（Markdown） ===")
    print("")
    print("| ファイル | 音声長 | モード | 処理時間 | RTF | セグメント数 |")
    print("|---|---|---|---|---|---|")
    for r in allResults {
        let durMin = String(format: "%.1f分", r.durationSec / 60)
        let elapsed = String(format: "%.1fs", r.elapsedSec)
        let rtf = String(format: "%.3fx", r.rtf)
        print("| \(r.file) | \(durMin) | \(r.mode) | \(elapsed) | \(rtf) | \(r.segmentCount) |")
    }
    print("")
    print("=== ベンチマーク完了 ===")
}

try await main()
