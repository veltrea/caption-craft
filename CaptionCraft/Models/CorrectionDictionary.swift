import Foundation

// MARK: - CorrectionDictionary

/// 書き起こし校正用の辞書。アプリ全体で共有し、プロジェクト横断で使い回す。
///
/// 成熟度: experimental
struct CorrectionDictionary: Codable {

    static func intent() -> String {
        """
        役割: Whisper 誤認識パターンの辞書データ。
              アプリ全体で共有 (プロジェクト単位ではない)。
              DictionaryStore が JSON 永続化を担当する。
        成熟度: experimental
        依存: なし (純粋データ型)
        変更時の注意: entries のキーを変えると既存辞書が読めなくなる。
        """
    }

    var entries: [DictionaryEntry] = []

    /// エントリを wrong テキストで検索。
    func findEntries(matching text: String) -> [DictionaryEntry] {
        entries.filter { entry in
            if entry.caseSensitive {
                return text.contains(entry.wrong)
            } else {
                return text.localizedStandardContains(entry.wrong)
            }
        }
    }
}

// MARK: - DictionaryEntry

/// 辞書の 1 エントリ。「この誤認識をこう直す」のペア。
struct DictionaryEntry: Codable, Identifiable {
    let id: UUID
    /// 誤認識パターン (例: "quad code")。
    var wrong: String
    /// 正しい表記 (例: "Claude Code")。
    var correct: String
    /// 大小文字を区別するか。
    var caseSensitive: Bool
    /// 登録元。
    var source: DictionaryEntrySource
    /// 適用回数。
    var useCount: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        wrong: String,
        correct: String,
        caseSensitive: Bool = false,
        source: DictionaryEntrySource = .manual,
        useCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.wrong = wrong
        self.correct = correct
        self.caseSensitive = caseSensitive
        self.source = source
        self.useCount = useCount
        self.createdAt = createdAt
    }
}

// MARK: - DictionaryEntrySource

/// 辞書エントリの登録元。
enum DictionaryEntrySource: String, Codable {
    /// ユーザー修正の diff から自動学習。
    case autoLearned
    /// ユーザーが辞書画面から手動登録。
    case manual
    /// LLM が提案し、ユーザーが承認。
    case llmSuggested
}

// MARK: - CorrectionContext

/// LLM による文脈推定の結果。
///
/// 成熟度: experimental
struct CorrectionContext: Codable {

    static func intent() -> String {
        """
        役割: LLM が推定した動画の文脈情報。
              CorrectionService が生成し、LLM 一括校正のプロンプトに使う。
        成熟度: experimental
        依存: なし (純粋データ型)
        """
    }

    /// 推定ドメイン (例: "AI開発ツールの紹介動画")。
    let domain: String
    /// ドメイン固有の重要語 (例: ["Claude", "LLM", "API"])。
    let keyTerms: [String]
    /// LLM が提案した修正候補。
    let suggestedCorrections: [SuggestedCorrection]
}

// MARK: - SuggestedCorrection

/// LLM が提案した修正候補 1 件。
struct SuggestedCorrection: Codable {
    let wrong: String
    let correct: String
    /// LLM の確信度 (0-1)。
    let confidence: Double
    /// なぜこの修正が必要か。
    let reasoning: String
}
