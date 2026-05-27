import Foundation
import SwiftUI

// MARK: - EnsembleCheckSession

/// クロスチェック（複数エンジン比較）の1セッションを管理する ObservableObject。
/// シート表示と同時に全副エンジンを逐次実行し、結果を蓄積表示する。
///
/// 成熟度: experimental
@MainActor
final class EnsembleCheckSession: ObservableObject, Identifiable {

    let id = UUID()
    let regionID: UUID
    let originalText: String
    let primaryEngine: STTEngineType
    let secondaryEngines: [STTEngineType]
    let timeRangeLabel: String

    @Published var language: String
    @Published var results: [STTEngineType: EngineResult] = [:]
    /// ユーザーが編集中のテキスト。初期値は現在の字幕テキスト。
    @Published var editedText: String

    // MARK: - EngineResult

    struct EngineResult: Equatable {
        var phase: Phase = .waiting
        var fullText: String = ""
        var similarity: Double = 0
        var errorMessage: String?

        enum Phase: Equatable {
            case waiting
            case preparing
            case transcribing
            case completed(matched: Bool)
            case failed
        }

        var isFinished: Bool {
            switch phase {
            case .completed, .failed: return true
            default: return false
            }
        }
    }

    // MARK: - Init

    init(region: CaptionRegion, primary: STTEngineType, secondaries: [STTEngineType]) {
        self.regionID = region.id
        self.originalText = region.text
        self.primaryEngine = primary
        self.secondaryEngines = secondaries
        self.timeRangeLabel = "\(Self.formatMs(region.startMs)) – \(Self.formatMs(region.endMs))"
        self.language = region.sourceLanguage
        self.editedText = region.text
        for engine in secondaries {
            results[engine] = EngineResult()
        }
    }

    // MARK: - State updates

    func setPhase(_ phase: EngineResult.Phase, for engine: STTEngineType) {
        results[engine]?.phase = phase
    }

    func applyResult(for engine: STTEngineType, text: String) {
        guard !text.isEmpty else {
            results[engine]?.phase = .failed
            results[engine]?.errorMessage = "結果が空でした"
            return
        }
        results[engine]?.fullText = text
        let sim = Self.similarity(originalText, text)
        results[engine]?.similarity = sim
        results[engine]?.phase = .completed(matched: sim >= 0.99)
    }

    func markFailed(for engine: STTEngineType, message: String) {
        results[engine]?.phase = .failed
        results[engine]?.errorMessage = message
    }

    var allFinished: Bool {
        secondaryEngines.allSatisfy { results[$0]?.isFinished ?? false }
    }

    /// ユーザーが字幕テキストを変更したか。
    var isTextEdited: Bool {
        editedText != originalText
    }

    /// 再実行のため全エンジンの状態をリセットする。
    func resetAll() {
        for engine in secondaryEngines {
            results[engine] = EngineResult()
        }
    }

    // MARK: - Diff (単語レベル)

    struct DiffWord: Identifiable {
        let id: Int
        let text: String
        let isDifferent: Bool
    }

    /// 主エンジン結果と副エンジン結果を単語レベルで比較し、差分を返す。
    /// LCS（最長共通部分列）で一致単語を特定し、それ以外を差分としてマークする。
    static func diffWords(primary: String, secondary: String) -> [DiffWord] {
        let pWords = normalizeToWords(primary)
        let sDisplay = secondary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let sNorm = normalizeToWords(secondary)
        guard !sDisplay.isEmpty else { return [] }
        guard !pWords.isEmpty else {
            return sDisplay.enumerated().map { DiffWord(id: $0.offset, text: $0.element, isDifferent: true) }
        }

        let matched = lcsMatchedIndices(pWords, sNorm)

        return sDisplay.enumerated().map { (idx, word) in
            DiffWord(id: idx, text: word, isDifferent: !matched.contains(idx))
        }
    }

    private static func normalizeToWords(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    /// LCS のバックトラックで、secondary 側の一致インデックスを返す。
    private static func lcsMatchedIndices(_ a: [String], _ b: [String]) -> Set<Int> {
        let m = a.count, n = b.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        var matched = Set<Int>()
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                matched.insert(j - 1)
                i -= 1; j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matched
    }

    // MARK: - Similarity

    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return 1.0 }
        let distance = levenshtein(na, nb)
        let maxLen = max(na.count, nb.count)
        if maxLen == 0 { return 1.0 }
        return max(0.0, 1.0 - Double(distance) / Double(maxLen))
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                dp[i][j] = min(
                    dp[i - 1][j] + 1,
                    dp[i][j - 1] + 1,
                    dp[i - 1][j - 1] + cost
                )
            }
        }
        return dp[m][n]
    }

    // MARK: - Format

    private static func formatMs(_ ms: Int) -> String {
        let totalSec = ms / 1000
        let m = totalSec / 60
        let s = totalSec % 60
        let mss = ms % 1000
        return String(format: "%02d:%02d.%03d", m, s, mss)
    }
}
