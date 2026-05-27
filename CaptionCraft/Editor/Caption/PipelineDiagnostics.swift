import AudioCommon
import Foundation

/// パイプライン完了後に空リージョンを徹底診断するツール。
/// 各空リージョンについて:
///   1. 音声チャンクを WAV ファイルとして書き出し（ユーザーが耳で確認可能）
///   2. RMS エネルギー + ピーク振幅を測定（無音 / ノイズ / 音声の判別）
///   3. 複数言語で再 ASR を実行（言語検出漏れの発見）
///   4. 診断レポートを出力
///
/// 成熟度: experimental
final class PipelineDiagnostics {

    // MARK: - 診断結果

    struct RegionDiagnosis {
        let startMs: Int
        let endMs: Int
        let durationMs: Int
        let rmsEnergy: Float
        let peakAmplitude: Float
        let category: AudioCategory
        let wavPath: String
        let reTranscriptions: [(language: String, text: String)]
    }

    enum AudioCategory: String {
        case silence = "無音"
        case lowEnergy = "低エネルギー（ノイズ/BGM）"
        case hasAudio = "音声あり"
    }

    // MARK: - メイン診断

    /// 空リージョンを診断し、WAV + エネルギー + 再ASR の結果を返す。
    /// - Parameters:
    ///   - regions: 全 CaptionRegion（空のものだけ自動フィルタ）
    ///   - audioURL: 元音声ファイルの URL
    ///   - engine: 準備済みの CaptionEngine
    ///   - testLanguages: 再 ASR で試す言語リスト (例: ["ja", "en", "fr"])
    /// - Returns: 各空リージョンの診断結果
    static func diagnoseEmptyRegions(
        regions: [CaptionRegion],
        audioURL: URL,
        engine: CaptionEngine,
        testLanguages: [String]
    ) async -> [RegionDiagnosis] {
        let emptyRegions = regions.filter {
            !$0.isManuallyEdited && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !emptyRegions.isEmpty else {
            NSLog("[Diagnostics] 空リージョンなし — 診断スキップ")
            return []
        }

        NSLog("[Diagnostics] 空リージョン %d 件を診断開始", emptyRegions.count)

        // 音声を一括ロード（チャンク抽出のため）
        let allSamples: [Float]
        do {
            allSamples = try AudioFileLoader.load(url: audioURL, targetSampleRate: 16_000)
        } catch {
            NSLog("[Diagnostics] 音声ロード失敗: %@", error.localizedDescription)
            return []
        }

        // 出力ディレクトリ
        let outputDir = Self.makeOutputDir()
        NSLog("[Diagnostics] 出力先: %@", outputDir.path)

        var diagnoses: [RegionDiagnosis] = []

        for (i, region) in emptyRegions.enumerated() {
            let startSample = max(0, region.startMs * 16_000 / 1000)
            let endSample = min(allSamples.count, region.endMs * 16_000 / 1000)
            guard startSample < endSample else { continue }

            let chunk = Array(allSamples[startSample..<endSample])
            let durationMs = region.endMs - region.startMs

            // 1. エネルギー測定
            let (rms, peak) = measureEnergy(chunk)
            let category = categorize(rms: rms, peak: peak)

            // 2. WAV 書き出し
            let wavName = String(format: "empty_%03d_%d-%d.wav", i + 1, region.startMs, region.endMs)
            let wavURL = outputDir.appendingPathComponent(wavName)
            do {
                try writeWAV(samples: chunk, sampleRate: 16_000, to: wavURL)
            } catch {
                NSLog("[Diagnostics] WAV 書き出し失敗 #%d: %@", i + 1, error.localizedDescription)
            }

            // 3. 複数言語で再 ASR
            var reTranscriptions: [(language: String, text: String)] = []
            if category != .silence {
                for lang in testLanguages {
                    do {
                        let text = try await engine.transcribeSamples(
                            samples: chunk,
                            sampleRate: 16_000,
                            language: lang
                        )
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        reTranscriptions.append((language: lang, text: trimmed))
                    } catch {
                        reTranscriptions.append((language: lang, text: "[ERROR: \(error.localizedDescription)]"))
                    }
                }
            }

            let diagnosis = RegionDiagnosis(
                startMs: region.startMs,
                endMs: region.endMs,
                durationMs: durationMs,
                rmsEnergy: rms,
                peakAmplitude: peak,
                category: category,
                wavPath: wavURL.path,
                reTranscriptions: reTranscriptions
            )
            diagnoses.append(diagnosis)

            NSLog("[Diagnostics] #%d [%d-%d] (%dms) RMS=%.4f Peak=%.4f → %@",
                  i + 1, region.startMs, region.endMs, durationMs, rms, peak, category.rawValue)
            for rt in reTranscriptions {
                let display = rt.text.isEmpty ? "(空)" : "\"\(rt.text.prefix(60))\""
                NSLog("[Diagnostics]   %@: %@", rt.language, display)
            }
        }

        // 4. レポート書き出し
        let reportURL = outputDir.appendingPathComponent("diagnostic_report.txt")
        writeReport(diagnoses, to: reportURL)
        NSLog("[Diagnostics] レポート出力: %@", reportURL.path)
        NSLog("[Diagnostics] 診断完了: %d 件", diagnoses.count)

        return diagnoses
    }

    // MARK: - エネルギー測定

    /// RMS エネルギーとピーク振幅を返す。
    static func measureEnergy(_ samples: [Float]) -> (rms: Float, peak: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var sumSquares: Double = 0
        var peak: Float = 0
        for s in samples {
            sumSquares += Double(s * s)
            let abs = Swift.abs(s)
            if abs > peak { peak = abs }
        }
        let rms = Float(sqrt(sumSquares / Double(samples.count)))
        return (rms, peak)
    }

    /// エネルギーからカテゴリを判定。
    static func categorize(rms: Float, peak: Float) -> AudioCategory {
        // 無音: RMS < 0.005 かつ Peak < 0.02
        if rms < 0.005 && peak < 0.02 { return .silence }
        // 低エネルギー: RMS < 0.02（BGM、環境音、かすかな音）
        if rms < 0.02 { return .lowEnergy }
        return .hasAudio
    }

    // MARK: - WAV 書き出し

    /// Float32 サンプルを 16-bit PCM WAV として書き出す。
    static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2) // 16-bit = 2 bytes per sample
        let fileSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(Int(44 + dataSize))

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        // Float32 → Int16 変換
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        try data.write(to: url)
    }

    // MARK: - レポート出力

    static func writeReport(_ diagnoses: [RegionDiagnosis], to url: URL) {
        var lines: [String] = []
        lines.append("CaptionCraft Pipeline Diagnostics — 空リージョン診断レポート")
        lines.append("生成日時: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("対象: \(diagnoses.count) 件の空リージョン")
        lines.append("")

        // サマリ
        let silenceCount = diagnoses.filter { $0.category == .silence }.count
        let lowCount = diagnoses.filter { $0.category == .lowEnergy }.count
        let audioCount = diagnoses.filter { $0.category == .hasAudio }.count
        let rescuable = diagnoses.filter { d in
            d.reTranscriptions.contains { !$0.text.isEmpty && !$0.text.hasPrefix("[ERROR") }
        }.count

        lines.append("--- サマリ ---")
        lines.append("  無音:             \(silenceCount) 件")
        lines.append("  低エネルギー:     \(lowCount) 件")
        lines.append("  音声あり:         \(audioCount) 件")
        lines.append("  再ASRで救済可能:  \(rescuable) 件")
        lines.append("")

        // 詳細
        lines.append("--- 詳細 ---")
        for (i, d) in diagnoses.enumerated() {
            let timeStart = formatTime(ms: d.startMs)
            let timeEnd = formatTime(ms: d.endMs)
            lines.append("#\(i + 1) [\(timeStart) → \(timeEnd)] (\(d.durationMs)ms)")
            lines.append("  エネルギー: RMS=\(String(format: "%.4f", d.rmsEnergy)) Peak=\(String(format: "%.4f", d.peakAmplitude))")
            lines.append("  判定: \(d.category.rawValue)")
            lines.append("  WAV: \(d.wavPath)")

            if d.reTranscriptions.isEmpty {
                lines.append("  再ASR: (スキップ — 無音のため)")
            } else {
                for rt in d.reTranscriptions {
                    let display = rt.text.isEmpty ? "(空)" : "\"\(rt.text)\""
                    let marker = (!rt.text.isEmpty && !rt.text.hasPrefix("[ERROR")) ? " ★救済可能" : ""
                    lines.append("  再ASR [\(rt.language)]: \(display)\(marker)")
                }
            }
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - ユーティリティ

    private static func makeOutputDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("captioncraft-diagnostics")
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = base.appendingPathComponent(timestamp)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func formatTime(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let millis = ms % 1000
        return String(format: "%02d:%02d.%03d", minutes, seconds, millis)
    }
}
