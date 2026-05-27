import Foundation
import WhisperKit
import AVFoundation

// WhisperKit 単体ストレステスト
// 長い音声ファイルを transcribe(audioPath:) で処理し、
// CoreML の GPU クラッシュが再現するか確認する。

func run() async throws {
        let audioPath = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : NSString("~/Library/Application Support/CaptionCraft/ytcache/Gq5om1Z-I9M.mp4").expandingTildeInPath

        guard FileManager.default.fileExists(atPath: audioPath) else {
            print("ERROR: ファイルが見つかりません: \(audioPath)")
            Foundation.exit(1)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioPath)[.size] as? Int) ?? 0
        print("=== WhisperKit ストレステスト ===")
        print("ファイル: \(audioPath)")
        print("サイズ: \(fileSize / 1_000_000) MB")
        print("")

        // モデル準備 (ANE を除外して CPU+GPU のみ)
        let computeOpts = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU,
            prefillCompute: .cpuOnly
        )
        print("[1/3] WhisperKit 初期化中… (ANE無効: cpuAndGPU)")
        let initStart = Date()
        let pipe = try await WhisperKit(
            model: "openai_whisper-large-v3",
            computeOptions: computeOpts,
            verbose: false,
            logLevel: .error
        )
        let initElapsed = Date().timeIntervalSince(initStart)
        print("[1/3] 初期化完了: \(String(format: "%.1f", initElapsed))s")

        // 音声長取得
        let asset = AVURLAsset(url: URL(fileURLWithPath: audioPath))
        let duration = try await asset.load(.duration)
        let totalSec = CMTimeGetSeconds(duration)
        print("音声長: \(String(format: "%.1f", totalSec))s (\(String(format: "%.1f", totalSec / 60))分)")
        print("")

        // transcribe 実行
        print("[2/3] transcribe 開始 (wordTimestamps=true)…")
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = "ja"
        options.wordTimestamps = true

        var lastProgress = -1
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let pct = Int(pipe.progress.fractionCompleted * 100)
                if pct > lastProgress {
                    lastProgress = pct
                    let elapsed = Date().timeIntervalSince(initStart)
                    print("  進捗: \(pct)% (経過: \(String(format: "%.0f", elapsed))s)")
                }
            }
        }

        var segmentCount = 0
        pipe.segmentDiscoveryCallback = { segments in
            segmentCount += segments.count
            let last = segments.last
            let text = (last?.text ?? "").prefix(40)
            let endSec = last.map { String(format: "%.1f", $0.end) } ?? "?"
            print("  セグメント発見: 累計\(segmentCount)件 最新=[…\(endSec)s] \"\(text)\"")
        }

        let transcribeStart = Date()
        do {
            let results = try await pipe.transcribe(
                audioPath: audioPath,
                decodeOptions: options
            )
            progressTask.cancel()

            let transcribeElapsed = Date().timeIntervalSince(transcribeStart)
            let totalSegments = results.flatMap { $0.segments }
            print("")
            print("[3/3] transcribe 完了!")
            print("  経過時間: \(String(format: "%.1f", transcribeElapsed))s")
            print("  結果数: \(results.count)")
            print("  セグメント数: \(totalSegments.count)")
            print("  RTF (Real-Time Factor): \(String(format: "%.2f", transcribeElapsed / totalSec))x")
            if let first = totalSegments.first {
                print("  最初: [\(String(format: "%.1f", first.start))-\(String(format: "%.1f", first.end))s] \"\(first.text.prefix(50))\"")
            }
            if let last = totalSegments.last {
                print("  最後: [\(String(format: "%.1f", last.start))-\(String(format: "%.1f", last.end))s] \"\(last.text.prefix(50))\"")
            }
            print("")
            print("=== テスト成功: クラッシュなし ===")
        } catch {
            progressTask.cancel()
            let transcribeElapsed = Date().timeIntervalSince(transcribeStart)
            print("")
            print("=== テスト失敗 ===")
            print("  エラー: \(error)")
            print("  経過時間: \(String(format: "%.1f", transcribeElapsed))s")
            print("  その時点のセグメント数: \(segmentCount)")
            print("  進捗: \(lastProgress)%")
            Foundation.exit(1)
        }
}

try await run()
