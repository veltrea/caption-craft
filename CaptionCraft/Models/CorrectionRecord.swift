import Foundation

// MARK: - CorrectionRecord

/// 校正 1 件の記録。何を、誰が、何から何に直したか。
///
/// 成熟度: experimental
struct CorrectionRecord: Codable, Identifiable, Equatable {

    static func intent() -> String {
        """
        役割: 字幕テキストへの校正 1 件分を記録する不変データ。
              CaptionRegion.corrections に時系列で蓄積される。
        成熟度: experimental
        依存: なし (純粋データ型)
        変更時の注意: Codable のキーを変えると既存プロジェクト JSON が読めなくなる。
        """
    }

    let id: UUID
    /// 対象 CaptionRegion の ID。
    let regionID: UUID
    /// 校正前テキスト。
    let originalText: String
    /// 校正後テキスト。
    let correctedText: String
    /// 校正ソース。
    let source: CorrectionSource
    /// 校正実行日時。
    let timestamp: Date

    init(
        id: UUID = UUID(),
        regionID: UUID,
        originalText: String,
        correctedText: String,
        source: CorrectionSource,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.regionID = regionID
        self.originalText = originalText
        self.correctedText = correctedText
        self.source = source
        self.timestamp = timestamp
    }
}

// MARK: - CorrectionSource

/// 校正の実行者。
enum CorrectionSource: String, Codable {
    /// 辞書ベース自動置換。
    case dictionary
    /// LLM による文脈校正。
    case llm
    /// ユーザーの手動修正。
    case userEdit
}
