import Foundation

// MARK: - STTEngineType

/// CaptionCraft が対応する音声認識エンジンの種別。
///
/// 各エンジンは得意言語と特性が異なるため、ユーザーが環境設定で
/// 主エンジンを選択する。副エンジンはオンデマンドのアンサンブルチェックに使う。
///
/// 成熟度: experimental
enum STTEngineType: String, CaseIterable, Codable, Identifiable {
    /// OpenAI Whisper Large v3 (WhisperKit / CoreML)。99言語対応の汎用モデル。
    case whisper
    /// NVIDIA Parakeet TDT v3 (soniqo/speech-swift / CoreML+ANE)。
    /// 25 欧州言語に特化。Whisper より高速・高精度 (英欧州言語限定)。
    case parakeet
    /// Alibaba Qwen3-ASR (soniqo/speech-swift / MLX)。
    /// 52言語対応。コードスイッチング (混合言語) をネイティブ処理。
    /// 言語自動検出 + 書き起こしを一体で実行するため、Whisper の翻訳問題が発生しない。
    case qwen3
    /// faster-whisper (CTranslate2 / Python HTTP サーバー)。
    /// Whisper Large v3 の CTranslate2 int8 量子化実装。
    /// 多言語混合動画向け: 各チャンクで言語自動検出し、原語のまま書き起こす。
    /// 翻訳しない。言語学習者向け。
    case fasterWhisper

    var id: String { rawValue }

    /// UI 表示名。
    var displayName: String {
        switch self {
        case .whisper:    return "Whisper Large v3"
        case .parakeet:   return "Parakeet TDT v3"
        case .qwen3:      return "Qwen3-ASR"
        case .fasterWhisper: return "faster-whisper (多言語)"
        }
    }

    /// 環境設定での説明文 (得意言語と特性)。
    var summary: String {
        switch self {
        case .whisper:
            return "OpenAI Whisper Large v3。99言語対応。日本語・中国語・韓国語・ロシア語など多言語に強い。汎用向け。"
        case .parakeet:
            return "NVIDIA Parakeet TDT v3。25 欧州言語限定 (英・仏・独・伊・西など)。日本語非対応。Neural Engine ネイティブで Whisper より高速。"
        case .qwen3:
            return "Alibaba Qwen3-ASR。52言語対応。混合言語 (コードスイッチング) を自動検出して正しく書き起こす。多言語動画に最適。"
        case .fasterWhisper:
            return "faster-whisper (CTranslate2)。各チャンクで言語自動検出し原語のまま書き起こす。翻訳しない。多言語混合動画に最適。言語学習者向け。"
        }
    }

    /// このエンジンが対応する言語コード (ISO 639-1) の集合。
    /// "auto" を返したい場合は呼び出し側で別途扱う。
    var supportedLanguageCodes: Set<String> {
        switch self {
        case .whisper:
            // Whisper は実質ほぼ全言語。詳細列挙はせず、対応外を空集合で表現するため
            // ここでは「サポート判定で常に true を返す」マーカー的扱いに使う。
            return [] // 空集合 = 「すべて対応」と解釈する
        case .parakeet:
            // Parakeet TDT v3 が学習で対応する 25 欧州言語。
            // 出典: https://github.com/soniqo/speech-swift (Parakeet 説明)
            return [
                "en", "es", "fr", "de", "it", "pt", "nl", "pl",
                "ru", "uk", "cs", "sk", "hu", "ro", "bg", "hr",
                "sl", "sr", "et", "lt", "lv", "fi", "sv", "da", "no"
            ]
        case .qwen3:
            // Qwen3-ASR は 52 言語対応。空集合 = 「すべて対応」扱い。
            return []
        case .fasterWhisper:
            // faster-whisper は Whisper Large v3 と同じ 99 言語対応。
            return []
        }
    }

    /// VADなしモードをサポートするか。
    /// Whisper 系エンジンは内部でタイムスタンプ付きセグメント分割を行えるため対応。
    /// 非 Whisper エンジンは 30 秒チャンクが丸ごと 1 リージョンになるため非対応。
    var supportsNoVAD: Bool {
        switch self {
        case .whisper, .fasterWhisper: return true
        case .parakeet, .qwen3:        return false
        }
    }

    /// 指定言語コードをこのエンジンが扱えるか。
    /// "auto" は常に true (エンジン側で言語自動検出する)。
    func supports(language: String) -> Bool {
        if language == "auto" { return true }
        if supportedLanguageCodes.isEmpty { return true } // Whisper 等の「全対応」
        return supportedLanguageCodes.contains(language)
    }
}

// MARK: - WhisperModelVariant

/// WhisperKit で使用するモデルバリアント。
/// HuggingFace リポジトリ (argmaxinc/whisperkit-coreml) の variant 名に対応。
enum WhisperModelVariant: String, CaseIterable, Codable, Identifiable {
    case tiny       = "openai_whisper-tiny"
    case base       = "openai_whisper-base"
    case small      = "openai_whisper-small"
    case medium     = "openai_whisper-medium"
    case largev3    = "openai_whisper-large-v3"
    case turbo      = "openai_whisper-large-v3-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny:    return "Tiny (39M)"
        case .base:    return "Base (74M)"
        case .small:   return "Small (244M)"
        case .medium:  return "Medium (769M)"
        case .largev3: return "Large v3 (1.5B)"
        case .turbo:   return "Large v3 Turbo (809M)"
        }
    }

    var summary: String {
        switch self {
        case .tiny:    return "最軽量。速度最優先、精度は低い。"
        case .base:    return "軽量。短い動画のラフ文字起こしに。"
        case .small:   return "バランス型。日常的な用途に十分な精度。"
        case .medium:  return "高精度。多言語対応が安定。処理時間はやや長い。"
        case .largev3: return "最高精度。全言語で最良の結果。処理は重い。"
        case .turbo:   return "Large v3 の蒸留版。Large に近い精度で約3倍高速。"
        }
    }
}
