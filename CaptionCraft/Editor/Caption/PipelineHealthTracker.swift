import Foundation

/// パイプライン全体のエラーを集約するトラッカー。
/// パイプライン開始時に生成し、各フェーズで記録し、終了時にレポートを出す。
///
/// 成熟度: experimental
final class PipelineHealthTracker: @unchecked Sendable {
    private let lock = NSLock()

    // ASR
    private(set) var asrTotal = 0
    private(set) var asrEmpty = 0
    private(set) var asrFailed = 0
    private(set) var asrSkipped = 0

    // エンジン再初期化
    private(set) var engineRestarts = 0
    private(set) var engineRestartsFailed = 0

    // updateRegionText
    private(set) var writeSuccess = 0
    private(set) var writeNoMatch = 0

    // タイムスタンプ
    let startedAt = Date()

    // MARK: - 記録

    func recordASR(empty: Bool) {
        lock.lock()
        asrTotal += 1
        if empty { asrEmpty += 1 }
        lock.unlock()
    }

    func recordASRFailed() {
        lock.lock()
        asrTotal += 1
        asrFailed += 1
        lock.unlock()
    }

    func recordASRSkipped() {
        lock.lock()
        asrSkipped += 1
        lock.unlock()
    }

    func recordEngineRestart(success: Bool) {
        lock.lock()
        engineRestarts += 1
        if !success { engineRestartsFailed += 1 }
        lock.unlock()
    }

    func recordWrite(matched: Bool) {
        lock.lock()
        if matched { writeSuccess += 1 } else { writeNoMatch += 1 }
        lock.unlock()
    }

    // MARK: - 最終レポート

    /// パイプライン終了時に呼ぶ。全 region をスキャンして空をログに残す。
    func finalReport(regions: [CaptionRegion]) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let total = regions.count
        let emptyRegions = regions.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let emptyCount = emptyRegions.count
        let filledCount = total - emptyCount

        NSLog("[Pipeline Report] %.1fs 経過", elapsed)
        NSLog("[Pipeline Report] ASR: %d 件処理 (空=%d 失敗=%d スキップ=%d)",
              asrTotal, asrEmpty, asrFailed, asrSkipped)
        NSLog("[Pipeline Report] 書き込み: 成功=%d マッチなし=%d", writeSuccess, writeNoMatch)
        NSLog("[Pipeline Report] エンジン再起動: %d 回 (失敗=%d)", engineRestarts, engineRestartsFailed)
        NSLog("[Pipeline Report] 最終 region: %d 件 (テキスト有=%d 空=%d)", total, filledCount, emptyCount)

        if emptyCount > 0 {
            NSLog("[Pipeline Report] ⚠ 空 region %d 件の詳細:", emptyCount)
            for (i, r) in emptyRegions.enumerated() {
                let durationMs = r.endMs - r.startMs
                NSLog("[Pipeline Report]   #%d [%d-%d] (%dms) confidence=%.1f",
                      i + 1, r.startMs, r.endMs, durationMs, r.confidence)
            }
        }

        if writeNoMatch > 0 {
            NSLog("[Pipeline Report] ⚠ ASR テキストが %d 件書き込み先を見つけられず破棄された", writeNoMatch)
        }

        let errorRate = total > 0 ? Double(emptyCount) / Double(total) : 0
        if errorRate > 0.2 {
            NSLog("[Pipeline Report] ‼ エラー率 %.0f%% — エンジンに深刻な問題の可能性", errorRate * 100)
        }
    }
}

// CaptionRegion を直接渡せるよう import 不要 (同モジュール内)
