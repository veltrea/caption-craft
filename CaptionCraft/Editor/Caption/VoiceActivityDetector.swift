import Foundation
import Accelerate
import AudioCommon
import SpeechVAD

// MARK: - VoiceActivityDetector

/// 音声から発話区間 (Speech Segments) を検出する。
///
/// 設計:
/// - **Silero VAD v5** を採用。Pyannote より 25× 高速 (28分音声で ~70秒)、
///   F1 97.5% と CaptionCraft (講演動画) には十分。Pyannote は研究用途向けで false alarm 多め。
/// - Silero は内部で全長を sliding window 処理するので、**外部チャンク分割は不要**
///   (むしろ境界で発話が途切れる害がある)。丸ごと渡す。
/// - MLX バックエンド (デフォルト) で Metal GPU 経由実行。
///
/// 設計方針:
/// - VAD は字幕生成の "タイムスタンプの真実の源" として使う。
///   ASR の内部タイムスタンプには依存しない。
/// - lazy load (初回 detect 時にモデル DL + ロード、~5MB)。
/// - 1 アプリ寿命で 1 インスタンスを使い回す。
/// - **@MainActor にしない**: MLX 推論を main で走らせると UI が固まるため、
///   detectSpeech の重い部分は detached Task で background に流す。
///
/// 成熟度: experimental
final class VoiceActivityDetector: @unchecked Sendable {

    /// 感度設定に応じた Silero VAD コンフィグを返す。
    static func vadConfig(for sensitivity: VADSensitivity) -> VADConfig {
        VADConfig(
            onset: sensitivity.sileroOnset,
            offset: sensitivity.sileroOffset,
            minSpeechDuration: 0.08,
            minSilenceDuration: 0.1,
            windowDuration: 0.032,
            stepRatio: 1.0
        )
    }

    /// VAD 検出結果の前後にパディングする ms 数。
    /// Silero/エネルギー VAD とも「確信できるほど音が立ち上がってから」発話と判定するため、
    /// 実際の発話開始より遅れる (~100-200ms)。終了側も同様に早めに切れがち。
    /// 業界標準として lead-in 100-200ms / trail-out 100-200ms を盛る。
    /// 150ms: 120ms では波形先頭が僅かにはみ出るケースがあったため拡張。
    private static let leadInMs = 150
    private static let trailOutMs = 100

    private let modelLock = NSLock()
    private var _model: SileroVADModel?

    private var model: SileroVADModel? {
        modelLock.lock()
        defer { modelLock.unlock() }
        return _model
    }

    /// ロード済みモデルを解放して Metal GPU メモリを返す。
    /// ASR 開始前に呼ぶことで GPU/ANE リソースの同時占有を防ぐ。
    /// 次回 prepare() で再ロードされる。
    func unloadModel() {
        modelLock.lock()
        let had = _model != nil
        _model = nil
        modelLock.unlock()
        if had {
            AppLog.caption.info("VAD モデルをアンロード (Metal GPU メモリ解放)")
        }
    }

    func isAvailable() async -> Bool { true }

    /// モデルを事前ロードする。
    /// 初回呼び出しで HuggingFace から DL (~5MB、Silero v5 MLX)。
    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws {
        if model != nil {
            progress(1.0)
            return
        }
        AppLog.caption.info("VAD prepare 開始: \(SileroVADModel.defaultModelId, privacy: .public)")
        progress(0.0)
        do {
            let m = try await SileroVADModel.fromPretrained(
                modelId: nil,
                engine: .mlx,
                cacheDir: nil,
                offlineMode: false,
                progressHandler: { fraction, status in
                    AppLog.caption.debug("VAD DL: \(Int(fraction * 100))% \(status, privacy: .public)")
                    progress(max(0.0, min(1.0, fraction)))
                }
            )
            modelLock.lock()
            _model = m
            modelLock.unlock()
            progress(1.0)
            AppLog.caption.info("VAD prepare 完了")
        } catch {
            AppLog.caption.error("VAD prepare 失敗: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// 発話区間を検出する。
    ///
    /// Silero は内部で 512 サンプル (32ms) 単位のチャンクベースモデルなので、
    /// 外部から 60 秒単位に分けて detectSpeech を呼んでも内部動作と整合する。
    /// これで「チャンク 1 つ完了 = 進捗 1/N」というリアルな進捗が出せる。
    ///
    /// チャンク境界で発話が分断される可能性があるが、後段で gap < 300ms のものは結合する。
    ///
    /// - Parameters:
    ///   - samples: 16kHz mono Float32 PCM
    ///   - sampleRate: 通常 16000
    ///   - progress: 0–1 の実進捗 (チャンク完了ごとに更新)
    ///   - onCumulativeUpdate: チャンク完了ごとに、その時点までに検出された累積発話区間を通知する。
    ///     ライブ波形表示に使う (UI 側で空字幕として描画してスクロールするなど)。
    ///     最終的な戻り値とは異なる場合がある (途中はチャンク境界マージ前の素の結果)。
    ///   - onRegionFinalized: VAD パイプラインの **ASR 並行実行用**。
    ///     チャンクの境界マージで「もう変動しないと確定したリージョン」を順次 emit する。
    ///     (チャンクの最後のリージョンは次チャンクの先頭と merge する可能性があるため保留される)
    ///     全体完了時には残り全てが emit される。
    func detectSpeech(
        samples: [Float],
        sampleRate: Int,
        sensitivity: VADSensitivity = .normal,
        calibration: VADCalibration? = nil,
        progress: @Sendable @escaping (Double) -> Void = { _ in },
        onCumulativeUpdate: @Sendable @escaping ([SpeechRegion]) -> Void = { _ in },
        onRegionFinalized: @Sendable @escaping (SpeechRegion) -> Void = { _ in }
    ) async throws -> [SpeechRegion] {
        if model == nil {
            try await prepare(progress: { _ in })
        }
        guard let model else {
            throw VADError.notReady
        }

        let chunkSec = 60
        let chunkSize = chunkSec * sampleRate

        let vadConfig = Self.vadConfig(for: sensitivity)

        // 短い音声は 1 回で処理
        if samples.count <= chunkSize {
            let result = try await Task.detached(priority: .userInitiated) { () -> [SpeechRegion] in
                let segments = model.detectSpeech(audio: samples, sampleRate: sampleRate, config: vadConfig)
                let sileroOut = segments.map { seg in
                    SpeechRegion(
                        startMs: Int(Double(seg.startTime) * 1000),
                        endMs: Int(Double(seg.endTime) * 1000)
                    )
                }
                let energyOut = EnergyVAD.detectEnergyRegions(samples: samples, sampleRate: sampleRate, sensitivity: sensitivity, calibration: calibration)
                let missed = EnergyVAD.findMisses(sileroRegions: sileroOut, energyRegions: energyOut)
                progress(1.0)
                return (sileroOut + missed).sorted { $0.startMs < $1.startMs }
            }.value
            onCumulativeUpdate(result)
            for r in result {
                onRegionFinalized(r)
            }
            return result
        }

        // 長い音声は 60 秒チャンクに区切って逐次処理 (各チャンク完了で進捗報告)
        let chunkCount = (samples.count + chunkSize - 1) / chunkSize
        AppLog.caption.info("VAD: \(samples.count) samples を \(chunkCount) チャンクに分割")

        let gapThresholdMs = 300
        var allRegions: [SpeechRegion] = []
        // パイプライン用: 既に finalized として emit したリージョンの個数。
        // チャンクの最後のリージョンは「次チャンク先頭と merge する可能性がある」ため保留する。
        var finalizedCount = 0

        for i in 0..<chunkCount {
            try Task.checkCancellation()
            let startSample = i * chunkSize
            let endSample = min(samples.count, startSample + chunkSize)
            let chunkOffsetMs = startSample * 1000 / sampleRate
            let chunkInferStart = Date()

            // 1. Silero VAD + 2. エネルギー VAD を同じチャンクに対して並行に実行し、
            //    Silero の取りこぼしをエネルギー側で救済する。両方とも detached で background。
            let (sileroRegions, rescuedRegions) = try await Task.detached(priority: .userInitiated) { () -> ([SpeechRegion], [SpeechRegion]) in
                let chunk = Array(samples[startSample..<endSample])
                // Silero
                let segments = model.detectSpeech(audio: chunk, sampleRate: sampleRate, config: vadConfig)
                let sileroOut = segments.map { seg in
                    SpeechRegion(
                        startMs: chunkOffsetMs + Int(Double(seg.startTime) * 1000),
                        endMs: chunkOffsetMs + Int(Double(seg.endTime) * 1000)
                    )
                }
                // エネルギー VAD でこのチャンクの「音があるか/無いか」マップを作る
                let energyOut = EnergyVAD.detectEnergyRegions(
                    samples: chunk,
                    sampleRate: sampleRate,
                    offsetMs: chunkOffsetMs,
                    sensitivity: sensitivity,
                    calibration: calibration
                )
                // Silero と被らないエネルギー region = 救済対象
                let missed = EnergyVAD.findMisses(sileroRegions: sileroOut, energyRegions: energyOut)
                return (sileroOut, missed)
            }.value
            let chunkInferElapsed = Date().timeIntervalSince(chunkInferStart)

            // Silero + 救済を結合 (時間順)
            let chunkRegions = (sileroRegions + rescuedRegions).sorted { $0.startMs < $1.startMs }
            allRegions.append(contentsOf: chunkRegions)
            // 累積マージ → パディング (UI / ASR 両方とも padded 版を見る)
            let totalSoFarMs = samples.count * 1000 / sampleRate
            let cumulativeMerged = mergeCloseRegions(allRegions, gapThresholdMs: gapThresholdMs)
            let cumulativePadded = padRegions(
                cumulativeMerged,
                totalDurationMs: totalSoFarMs,
                leadInMs: Self.leadInMs,
                trailOutMs: Self.trailOutMs
            )
            AppLog.caption.info("VAD chunk \(i + 1)/\(chunkCount) (\(String(format: "%.2f", chunkInferElapsed))s): Silero \(sileroRegions.count) + 救済 \(rescuedRegions.count) → cumulative \(cumulativePadded.count)")
            onCumulativeUpdate(cumulativePadded)

            // パイプライン: 「もう変動しない」と判定できるリージョンを emit する。
            // padding 分も考慮して、次チャンクの先頭リージョンと merge しないことを保証する境界。
            let isLastChunk = (i == chunkCount - 1)
            var emittedThisChunk = 0
            if isLastChunk {
                while finalizedCount < cumulativePadded.count {
                    onRegionFinalized(cumulativePadded[finalizedCount])
                    finalizedCount += 1
                    emittedThisChunk += 1
                }
            } else {
                // 次チャンクの先頭リージョンが leadIn 分だけ前倒しされ、gap 分の merge 可能性もあるので
                // safeBoundary は leadIn + gap + trailOut を引いて余裕を持つ
                let safeBoundaryMs = (i + 1) * chunkSize * 1000 / sampleRate
                    - Self.leadInMs - gapThresholdMs - Self.trailOutMs
                while finalizedCount < cumulativePadded.count {
                    let r = cumulativePadded[finalizedCount]
                    if r.endMs <= safeBoundaryMs {
                        onRegionFinalized(r)
                        finalizedCount += 1
                        emittedThisChunk += 1
                    } else {
                        break
                    }
                }
            }
            AppLog.caption.debug("VAD chunk \(i + 1) finalized emit: +\(emittedThisChunk) (total emitted: \(finalizedCount))")

            progress(Double(i + 1) / Double(chunkCount))
        }

        // 最終結果: マージ → パディング適用 (lead-in/trail-out で検出遅延を補正)
        let totalDurationMs = samples.count * 1000 / sampleRate
        let merged = mergeCloseRegions(allRegions, gapThresholdMs: gapThresholdMs)
        return padRegions(
            merged,
            totalDurationMs: totalDurationMs,
            leadInMs: Self.leadInMs,
            trailOutMs: Self.trailOutMs
        )
    }

    /// 各 SpeechRegion の前後に leadIn/trailOut を盛って、検出遅延を補正する。
    /// - 前のリージョンの末尾と被らないようにクリップ
    /// - 次のリージョンの先頭と被らないようにクリップ
    /// - 全体の境界 (0, totalDurationMs) も超えないようにクリップ
    private func padRegions(
        _ regions: [SpeechRegion],
        totalDurationMs: Int,
        leadInMs: Int,
        trailOutMs: Int
    ) -> [SpeechRegion] {
        guard !regions.isEmpty else { return regions }
        var result: [SpeechRegion] = []
        result.reserveCapacity(regions.count)
        for (i, r) in regions.enumerated() {
            let prevEnd = result.last?.endMs ?? 0
            let nextStart = (i + 1 < regions.count) ? regions[i + 1].startMs : totalDurationMs
            // lead-in
            let desiredStart = r.startMs - leadInMs
            let newStart = max(prevEnd, max(0, desiredStart))
            // trail-out
            let desiredEnd = r.endMs + trailOutMs
            let newEnd = min(nextStart - 1, min(totalDurationMs, desiredEnd))
            // 不正範囲ガード
            guard newStart < newEnd else {
                result.append(r) // パディング不能、元のまま
                continue
            }
            result.append(SpeechRegion(startMs: newStart, endMs: newEnd))
        }
        return result
    }

    /// 連続する SpeechRegion で gap が小さいものを結合する。
    private func mergeCloseRegions(_ regions: [SpeechRegion], gapThresholdMs: Int) -> [SpeechRegion] {
        guard regions.count > 1 else { return regions }
        var merged: [SpeechRegion] = []
        for r in regions {
            if let last = merged.last, r.startMs - last.endMs <= gapThresholdMs {
                merged[merged.count - 1] = SpeechRegion(startMs: last.startMs, endMs: r.endMs)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// 長すぎるリージョンを音量が最も低い箇所で分割する。
    /// WhisperKit は 30 秒チャンクで処理するため、30 秒超のリージョンは
    /// ASR が空結果を返しやすい。内部の無音（RMS が最小）箇所で分割する。
    private func splitLongRegions(
        _ regions: [SpeechRegion],
        samples: [Float],
        sampleRate: Int,
        maxDurationMs: Int = 25000
    ) -> [SpeechRegion] {
        var result: [SpeechRegion] = []
        let windowMs = 50
        let windowSamples = windowMs * sampleRate / 1000

        for region in regions {
            let durationMs = region.endMs - region.startMs
            if durationMs <= maxDurationMs {
                result.append(region)
                continue
            }

            // リージョン内の RMS をウィンドウごとに計算
            let startSample = max(0, region.startMs * sampleRate / 1000)
            let endSample = min(samples.count, region.endMs * sampleRate / 1000)
            guard endSample > startSample + windowSamples else {
                result.append(region)
                continue
            }

            var windowRMS: [(ms: Int, rms: Float)] = []
            var pos = startSample
            while pos + windowSamples <= endSample {
                var rms: Float = 0
                let slice = Array(samples[pos..<pos + windowSamples])
                slice.withUnsafeBufferPointer { buf in
                    vDSP_rmsqv(buf.baseAddress!, 1, &rms, vDSP_Length(buf.count))
                }
                let ms = region.startMs + (pos - startSample) * 1000 / sampleRate
                windowRMS.append((ms: ms, rms: rms))
                pos += windowSamples
            }

            // 分割: maxDurationMs 間隔で最小 RMS の位置を探す
            var splits: [SpeechRegion] = []
            var segStart = region.startMs

            while true {
                let segEndLimit = segStart + maxDurationMs
                if segEndLimit >= region.endMs {
                    splits.append(SpeechRegion(startMs: segStart, endMs: region.endMs))
                    break
                }

                // segStart + maxDurationMs/2 〜 segStart + maxDurationMs の範囲で
                // 最も静かな箇所を探す (あまり短い分割を避けるため後半で探す)
                let searchStartMs = segStart + maxDurationMs / 2
                let candidates = windowRMS.filter { $0.ms >= searchStartMs && $0.ms <= segEndLimit }
                if let best = candidates.min(by: { $0.rms < $1.rms }) {
                    splits.append(SpeechRegion(startMs: segStart, endMs: best.ms))
                    segStart = best.ms
                } else {
                    splits.append(SpeechRegion(startMs: segStart, endMs: segEndLimit))
                    segStart = segEndLimit
                }
            }
            result.append(contentsOf: splits)
        }
        return result
    }

    // MARK: - EnergyVAD 単体パス

    /// 音量 (RMS) ベースのみで発話区間を検出する。CPU のみ、GPU 不使用。
    /// SileroVAD と同じコールバック構成を持つので CaptionTranscriber 側の差し替えが容易。
    func detectSpeechEnergyOnly(
        samples: [Float],
        sampleRate: Int,
        sensitivity: VADSensitivity = .normal,
        calibration: VADCalibration? = nil,
        progress: @Sendable @escaping (Double) -> Void = { _ in },
        onCumulativeUpdate: @Sendable @escaping ([SpeechRegion]) -> Void = { _ in },
        onRegionFinalized: @Sendable @escaping (SpeechRegion) -> Void = { _ in }
    ) async throws -> [SpeechRegion] {

        let chunkSec = 60
        let chunkSize = chunkSec * sampleRate
        let gapThresholdMs = 300

        // 短い音声は 1 回で処理
        if samples.count <= chunkSize {
            try Task.checkCancellation()
            let regions = await Task.detached(priority: .userInitiated) { () -> [SpeechRegion] in
                EnergyVAD.detectEnergyRegions(samples: samples, sampleRate: sampleRate, sensitivity: sensitivity, calibration: calibration)
            }.value
            try Task.checkCancellation()
            let merged = mergeCloseRegions(regions, gapThresholdMs: gapThresholdMs)
            let totalMs = samples.count * 1000 / sampleRate
            let padded = padRegions(merged, totalDurationMs: totalMs, leadInMs: Self.leadInMs, trailOutMs: Self.trailOutMs)
            let split = splitLongRegions(padded, samples: samples, sampleRate: sampleRate)
            progress(1.0)
            onCumulativeUpdate(split)
            for r in split { onRegionFinalized(r) }
            return split
        }

        // 長い音声はチャンク分割
        let chunkCount = (samples.count + chunkSize - 1) / chunkSize
        var allRegions: [SpeechRegion] = []
        var finalizedCount = 0

        for i in 0..<chunkCount {
            try Task.checkCancellation()
            let startSample = i * chunkSize
            let endSample = min(samples.count, startSample + chunkSize)
            let chunkOffsetMs = startSample * 1000 / sampleRate

            let chunkRegions = await Task.detached(priority: .userInitiated) { () -> [SpeechRegion] in
                EnergyVAD.detectEnergyRegions(
                    samples: Array(samples[startSample..<endSample]),
                    sampleRate: sampleRate,
                    offsetMs: chunkOffsetMs,
                    sensitivity: sensitivity,
                    calibration: calibration
                )
            }.value
            try Task.checkCancellation()
            allRegions.append(contentsOf: chunkRegions)

            let totalSoFarMs = samples.count * 1000 / sampleRate
            let cumulativeMerged = mergeCloseRegions(allRegions, gapThresholdMs: gapThresholdMs)
            let cumulativePadded = padRegions(cumulativeMerged, totalDurationMs: totalSoFarMs, leadInMs: Self.leadInMs, trailOutMs: Self.trailOutMs)
            let cumulativeSplit = splitLongRegions(cumulativePadded, samples: samples, sampleRate: sampleRate)
            onCumulativeUpdate(cumulativeSplit)

            let isLastChunk = (i == chunkCount - 1)
            if isLastChunk {
                while finalizedCount < cumulativeSplit.count {
                    onRegionFinalized(cumulativeSplit[finalizedCount])
                    finalizedCount += 1
                }
            } else {
                let safeBoundaryMs = (i + 1) * chunkSize * 1000 / sampleRate
                    - Self.leadInMs - gapThresholdMs - Self.trailOutMs
                while finalizedCount < cumulativeSplit.count {
                    let r = cumulativeSplit[finalizedCount]
                    if r.endMs <= safeBoundaryMs {
                        onRegionFinalized(r)
                        finalizedCount += 1
                    } else {
                        break
                    }
                }
            }
            progress(Double(i + 1) / Double(chunkCount))
        }

        let totalDurationMs = samples.count * 1000 / sampleRate
        let merged = mergeCloseRegions(allRegions, gapThresholdMs: gapThresholdMs)
        let padded = padRegions(merged, totalDurationMs: totalDurationMs, leadInMs: Self.leadInMs, trailOutMs: Self.trailOutMs)
        let result = splitLongRegions(padded, samples: samples, sampleRate: sampleRate)

        // --- 診断: Silero VAD との比較 ---
        await diagCompareWithSilero(samples: samples, sampleRate: sampleRate, sensitivity: sensitivity, energyRegions: result)

        return result
    }

    /// Silero VAD を正解基準として Energy VAD の取りこぼしを定量化する診断メソッド。
    private func diagCompareWithSilero(
        samples: [Float],
        sampleRate: Int,
        sensitivity: VADSensitivity,
        energyRegions: [SpeechRegion]
    ) async {
        if model == nil { try? await prepare(progress: { _ in }) }
        guard let model else {
            AppLog.caption.warning("DIAG: Silero モデルをロードできず比較スキップ")
            return
        }

        let vadConfig = Self.vadConfig(for: sensitivity)
        let chunkSec = 60
        let chunkSize = chunkSec * sampleRate
        let chunkCount = max(1, (samples.count + chunkSize - 1) / chunkSize)
        var sileroRegions: [SpeechRegion] = []

        for i in 0..<chunkCount {
            let startSample = i * chunkSize
            let endSample = min(samples.count, startSample + chunkSize)
            let offsetMs = startSample * 1000 / sampleRate
            let chunk = Array(samples[startSample..<endSample])
            let segs = model.detectSpeech(audio: chunk, sampleRate: sampleRate, config: vadConfig)
            sileroRegions.append(contentsOf: segs.map {
                SpeechRegion(startMs: offsetMs + Int($0.startTime * 1000), endMs: offsetMs + Int($0.endTime * 1000))
            })
        }

        let sileroTotalMs = sileroRegions.reduce(0) { $0 + $1.durationMs }
        let energyTotalMs = energyRegions.reduce(0) { $0 + $1.durationMs }

        var missedMs = 0
        var missedRegions: [(SpeechRegion, Float)] = []
        for sr in sileroRegions {
            let covered = energyRegions.contains { er in er.startMs < sr.endMs && sr.startMs < er.endMs }
            if !covered {
                let startSample = max(0, sr.startMs * sampleRate / 1000)
                let endSample = min(samples.count, sr.endMs * sampleRate / 1000)
                var rms: Float = 0
                if endSample > startSample {
                    let slice = Array(samples[startSample..<endSample])
                    slice.withUnsafeBufferPointer { buf in
                        vDSP_rmsqv(buf.baseAddress!, 1, &rms, vDSP_Length(buf.count))
                    }
                }
                let db = EnergyVAD.toDecibels(rms)
                missedMs += sr.durationMs
                missedRegions.append((sr, db))
            }
        }

        let summary = "DIAG 比較: Silero \(sileroRegions.count) regions (\(sileroTotalMs)ms) vs Energy \(energyRegions.count) regions (\(energyTotalMs)ms) — Energy が見逃し: \(missedRegions.count) regions (\(missedMs)ms)"
        print("[DIAG] \(summary)")
        for (r, db) in missedRegions.prefix(30) {
            print("[MISS] [\(r.startMs)-\(r.endMs)ms] (\(r.durationMs)ms) rawRMS=\(String(format:"%.4f", pow(10, db/20))) \(String(format:"%.1f", db))dB")
        }
    }
}

// MARK: - EnergyVAD (RMS ベース発話区間検出)

/// RMS ベースの発話区間検出器。
///
/// 設計:
/// - 入力を RMS 正規化してから処理（録音レベルの差異を吸収）
/// - ウィンドウ単位で RMS を計算
/// - ヒステリシス閾値（Rabiner-Sambur 1975 方式）:
///   activation 閾値を超えたら発話開始、deactivation 閾値を下回ったら発話終了。
///   単一閾値で起きる境界チャタリングを防ぐ。
/// - Silero VAD の安全網としても使う（取りこぼし救済）
enum EnergyVAD {

    /// RMS 正規化の目標値。平均的な会話音声の RMS に合わせる。
    private static let targetRMS: Float = 0.05

    /// 局所 AGC（Automatic Gain Control）のチャンクサイズ（秒）。
    /// インタビュー動画でカメラマン（大声）と被写体（小声）が交互に出る場合、
    /// グローバル正規化では大声パートに引きずられて小声パートが閾値以下になる。
    /// チャンク単位で独立に正規化することで、各パートのレベルを揃える。
    private static let agcChunkSec: Double = 5.0

    /// チャンク単位の局所 RMS 正規化。各チャンクを独立に目標 RMS に揃える。
    private static func normalizeRMSLocal(_ samples: [Float], sampleRate: Int) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let chunkSize = Int(agcChunkSec * Double(sampleRate))
        var output = [Float](repeating: 0, count: samples.count)
        var offset = 0

        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            let count = end - offset

            // チャンクの RMS を測定
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buf in
                vDSP_rmsqv(buf.baseAddress! + offset, 1, &rms, vDSP_Length(count))
            }

            if rms > 1e-8 {
                // ゲインに上限を設ける（無音に近いチャンクを爆発的に増幅しない）
                let rawGain = targetRMS / rms
                var gain = min(rawGain, 20.0)
                samples.withUnsafeBufferPointer { inBuf in
                    output.withUnsafeMutableBufferPointer { outBuf in
                        vDSP_vsmul(
                            inBuf.baseAddress! + offset, 1,
                            &gain,
                            outBuf.baseAddress! + offset, 1,
                            vDSP_Length(count)
                        )
                    }
                }
            } else {
                // 無音チャンクはそのままコピー
                for i in offset..<end {
                    output[i] = samples[i]
                }
            }
            offset = end
        }

        // クリッピング防止
        var lo: Float = -1.0
        var hi: Float = 1.0
        output.withUnsafeMutableBufferPointer { buf in
            vDSP_vclip(buf.baseAddress!, 1, &lo, &hi, buf.baseAddress!, 1, vDSP_Length(buf.count))
        }
        return output
    }

    /// 25ms フレーム / 10ms ホップ（WebRTC・Kaldi 準拠）
    private static let frameSec: Double = 0.025
    private static let hopSec: Double = 0.010

    /// dB 変換の下限。デジタル無音で -inf にならないよう制限する。
    private static let dbFloor: Float = -80.0

    /// RMS → dB 変換。
    fileprivate static func toDecibels(_ rms: Float) -> Float {
        guard rms > 0 else { return dbFloor }
        return max(20.0 * log10(rms), dbFloor)
    }

    /// チャンク (16kHz Float32 PCM) からエネルギーベースの発話候補リージョンを返す。
    /// 生 PCM を dB (対数) ドメインで処理する。AGC は使わない。
    /// dB なら「ノイズより N dB 大きい」という加算で判定でき、録音レベルに依存しない。
    /// `offsetMs` を全リージョンの開始時刻に加算する (チャンク単位呼び出し用)。
    static func detectEnergyRegions(
        samples: [Float],
        sampleRate: Int,
        offsetMs: Int = 0,
        sensitivity: VADSensitivity = .normal,
        calibration: VADCalibration? = nil
    ) -> [SpeechRegion] {

        let frameSize = Int(frameSec * Double(sampleRate))
        let hopSize = Int(hopSec * Double(sampleRate))
        guard samples.count >= frameSize, hopSize > 0 else { return [] }

        let numFrames = (samples.count - frameSize) / hopSize + 1
        guard numFrames > 0 else { return [] }

        // 各フレームの RMS → dB（生 PCM をそのまま測定）
        var dbValues = [Float](repeating: 0, count: numFrames)
        samples.withUnsafeBufferPointer { buf in
            for i in 0..<numFrames {
                var rms: Float = 0
                vDSP_rmsqv(buf.baseAddress! + i * hopSize, 1, &rms, vDSP_Length(frameSize))
                dbValues[i] = toDecibels(rms)
            }
        }

        // メディアンフィルタ（5フレーム窓）で瞬間ノイズを除去
        let smoothed = medianFilter(dbValues, windowSize: 5)

        // 閾値決定 (dB ドメイン)
        let activationThDB: Float
        let deactivationThDB: Float
        if let cal = calibration {
            activationThDB = toDecibels(cal.activationThreshold)
            deactivationThDB = toDecibels(cal.deactivationThreshold)
        } else {
            let sorted = smoothed.sorted()
            let percentileIdx = min(max(0, Int(Double(sorted.count) * 0.1)), sorted.count - 1)
            let noiseFloorDB = sorted[percentileIdx]
            activationThDB = max(noiseFloorDB + sensitivity.energyActivationOffsetDB, sensitivity.energyMinActivationDB)
            deactivationThDB = max(noiseFloorDB + sensitivity.energyDeactivationOffsetDB, sensitivity.energyMinDeactivationDB)
            print("[EVAD] frames=\(numFrames) dB[min=\(String(format:"%.1f", sorted.first ?? 0)) p10=\(String(format:"%.1f", sorted[percentileIdx])) med=\(String(format:"%.1f", sorted[sorted.count/2])) max=\(String(format:"%.1f", sorted.last ?? 0))] noiseFloor=\(String(format:"%.1f", noiseFloorDB)) actTh=\(String(format:"%.1f", activationThDB)) deactTh=\(String(format:"%.1f", deactivationThDB))")
        }

        // ハングオーバー付きヒステリシスでリージョン検出
        let hangoverFrames = max(1, sensitivity.energyHangoverMs * sampleRate / (hopSize * 1000))
        var regions: [SpeechRegion] = []
        var inRegion = false
        var regionStartFrame = 0
        var hangoverCount = 0

        for i in 0..<numFrames {
            if !inRegion {
                if smoothed[i] > activationThDB {
                    regionStartFrame = i
                    inRegion = true
                    hangoverCount = 0
                }
            } else {
                if smoothed[i] >= deactivationThDB {
                    hangoverCount = 0
                } else {
                    hangoverCount += 1
                    if hangoverCount >= hangoverFrames {
                        let endFrame = i - hangoverCount + 1
                        let startMs = offsetMs + regionStartFrame * hopSize * 1000 / sampleRate
                        let endMs = offsetMs + endFrame * hopSize * 1000 / sampleRate
                        if endMs > startMs {
                            regions.append(SpeechRegion(startMs: startMs, endMs: endMs))
                        }
                        inRegion = false
                        hangoverCount = 0
                    }
                }
            }
        }
        if inRegion {
            let startMs = offsetMs + regionStartFrame * hopSize * 1000 / sampleRate
            let endMs = offsetMs + numFrames * hopSize * 1000 / sampleRate
            regions.append(SpeechRegion(startMs: startMs, endMs: endMs))
        }

        // 後方マージパス: リージョン間のギャップが短く、ギャップ内に発話フレームがあれば結合。
        // ハングオーバーで一瞬の無音で打ち切った後、すぐ発話が再開するケースを救済する。
        let mergeGapMs = 500
        var merged: [SpeechRegion] = []
        for region in regions {
            if let last = merged.last {
                let gapMs = region.startMs - last.endMs
                if gapMs > 0 && gapMs <= mergeGapMs {
                    // 絶対 ms → チャンク内フレームインデックスに変換
                    let gapStartFrame = max(0, (last.endMs - offsetMs) * sampleRate / (hopSize * 1000))
                    let gapEndFrame = min(numFrames, (region.startMs - offsetMs) * sampleRate / (hopSize * 1000))
                    if gapStartFrame < gapEndFrame {
                        let hasActivity = (gapStartFrame..<gapEndFrame).contains { smoothed[$0] > deactivationThDB }
                        if hasActivity {
                            merged[merged.count - 1] = SpeechRegion(startMs: last.startMs, endMs: region.endMs)
                            continue
                        }
                    }
                }
            }
            merged.append(region)
        }

        print("[EVAD] result: \(merged.count) regions (\(regions.count) before merge) from offset \(offsetMs)ms")
        return merged
    }

    /// メディアンフィルタ。瞬間的なスパイクやドロップを除去する。
    private static func medianFilter(_ values: [Float], windowSize: Int) -> [Float] {
        guard values.count > 1 else { return values }
        let half = windowSize / 2
        var result = [Float](repeating: 0, count: values.count)
        for i in 0..<values.count {
            let lo = max(0, i - half)
            let hi = min(values.count - 1, i + half)
            var window = Array(values[lo...hi])
            window.sort()
            result[i] = window[window.count / 2]
        }
        return result
    }

    /// 指定区間の RMS を測定する（キャリブレーション用）。
    /// 生 PCM の RMS を返す（AGC なし。VAD もAGC なしで動作するため条件が一致する）。
    static func measureRMS(samples: [Float], sampleRate: Int, startMs: Int, endMs: Int) -> Float {
        let startSample = max(0, startMs * sampleRate / 1000)
        let endSample = min(samples.count, endMs * sampleRate / 1000)
        guard endSample > startSample else { return 0 }
        var rms: Float = 0
        samples.withUnsafeBufferPointer { buf in
            vDSP_rmsqv(buf.baseAddress! + startSample, 1, &rms, vDSP_Length(endSample - startSample))
        }
        return rms
    }

    /// Silero の検出結果と被らないエネルギー region を「救済リージョン」として返す。
    static func findMisses(
        sileroRegions: [SpeechRegion],
        energyRegions: [SpeechRegion]
    ) -> [SpeechRegion] {
        return energyRegions.filter { e in
            !sileroRegions.contains { s in
                s.startMs < e.endMs && e.startMs < s.endMs
            }
        }
    }
}

// MARK: - SpeechRegion

/// VAD が検出した発話区間。
/// CaptionRegion とは別の概念 (CaptionRegion は字幕単位、SpeechRegion は連続発話単位)。
struct SpeechRegion: Equatable, Sendable {
    let startMs: Int
    let endMs: Int

    var durationMs: Int { max(0, endMs - startMs) }
}

// MARK: - VADError

enum VADError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady: return "VAD モデルがロードされていません"
        }
    }
}
