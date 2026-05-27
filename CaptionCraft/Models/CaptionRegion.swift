import CoreGraphics
import Foundation

// MARK: - CaptionRegion

/// タイムライン上の Caption (字幕) 区間。
/// Whisper による自動文字起こし結果の 1 セグメント、もしくは手動で追加された空 region。
///
/// 成熟度: experimental (FIX_10 Phase 1)
///
/// 設計メモ:
/// - `isManuallyEdited = true` の region は、トラック全体再合成時にも保護され上書きされない。
/// - `confidence` は Whisper の avg_logprob を 0–1 に正規化した値 (手修正済みは 1.0)。
/// - 音声ファイルは持たない。元動画 (MediaPaths.micAudioPath / screenVideoPath) を
///   CaptionTranscriber が直接読み取る。
struct CaptionRegion: Codable, Identifiable, Equatable, TimelineRegion {
    var id: UUID = UUID()
    var startMs: Int
    var endMs: Int
    var text: String = ""
    /// 翻訳テキスト。nil = 未翻訳。翻訳実行時にここに格納し、原文 text は保持する。
    var translatedText: String? = nil
    /// 翻訳先の言語コード (ISO 639-1)。nil = 未翻訳。
    var translatedLanguage: String? = nil
    /// 手動修正済みフラグ。true なら再合成時に保護される。
    var isManuallyEdited: Bool = false
    /// ISO 639-1 (例: "ja", "en")。"auto" は自動検出。
    var sourceLanguage: String = "ja"
    /// 0–1 の信頼度。低 (< 0.6) なら UI で ⚠ マーク表示。
    var confidence: Double = 1.0
    /// この region に適用された校正の履歴。空 = 未校正。
    var corrections: [CorrectionRecord] = []
    /// 校正前の原文 (Whisper 生出力)。nil = 校正未実施。
    var originalRawText: String? = nil
    /// アンサンブルチェックで他エンジンが返した結果。key = STTEngineType.rawValue。
    /// 例: ["parakeet": "Hello world", "qwen3": "Hello, world."]
    /// 空 = まだ別エンジンチェックを実行していない。
    var engineResults: [String: String] = [:]

    // 通常のメンバワイズ init を残しつつ、Codable は明示する
    // (既存 JSON に engineResults が無くてもデコードできるようにするため)。
    init(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int,
        text: String = "",
        translatedText: String? = nil,
        translatedLanguage: String? = nil,
        isManuallyEdited: Bool = false,
        sourceLanguage: String = "ja",
        confidence: Double = 1.0,
        corrections: [CorrectionRecord] = [],
        originalRawText: String? = nil,
        engineResults: [String: String] = [:]
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.translatedText = translatedText
        self.translatedLanguage = translatedLanguage
        self.isManuallyEdited = isManuallyEdited
        self.sourceLanguage = sourceLanguage
        self.confidence = confidence
        self.corrections = corrections
        self.originalRawText = originalRawText
        self.engineResults = engineResults
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try c.decodeIfPresent(UUID.self,                forKey: .id)                 ?? UUID()
        startMs            = try c.decode(Int.self,                         forKey: .startMs)
        endMs              = try c.decode(Int.self,                         forKey: .endMs)
        text               = try c.decodeIfPresent(String.self,             forKey: .text)               ?? ""
        translatedText     = try c.decodeIfPresent(String.self,             forKey: .translatedText)
        translatedLanguage = try c.decodeIfPresent(String.self,             forKey: .translatedLanguage)
        isManuallyEdited   = try c.decodeIfPresent(Bool.self,               forKey: .isManuallyEdited)   ?? false
        sourceLanguage     = try c.decodeIfPresent(String.self,             forKey: .sourceLanguage)     ?? "ja"
        confidence         = try c.decodeIfPresent(Double.self,             forKey: .confidence)         ?? 1.0
        corrections        = try c.decodeIfPresent([CorrectionRecord].self, forKey: .corrections)        ?? []
        originalRawText    = try c.decodeIfPresent(String.self,             forKey: .originalRawText)
        engineResults      = try c.decodeIfPresent([String: String].self,   forKey: .engineResults)      ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case id, startMs, endMs, text, translatedText, translatedLanguage
        case isManuallyEdited, sourceLanguage, confidence, corrections
        case originalRawText, engineResults
    }
}

// MARK: - CaptionRegion + Drawing

extension CaptionRegion {
    /// 与えられた描画領域 (rect) と動画尺 (durationMs) の中で、
    /// この region が占める矩形を返す。タイムライン上の帯描画用。
    func bandRect(in rect: CGRect, durationMs: Int) -> CGRect {
        guard durationMs > 0, rect.width > 0 else { return .zero }
        let pxPerMs = rect.width / CGFloat(durationMs)
        let x = CGFloat(startMs) * pxPerMs
        let w = max(1, CGFloat(endMs - startMs) * pxPerMs)
        return CGRect(x: x, y: 0, width: w, height: rect.height)
    }
}

// MARK: - VADMethod

/// 発話区間検出 (VAD) の方式。
/// - energy: 音量 (RMS) ベース。CPU のみで高速。クリーンな音声向き。
/// - silero: Silero VAD v5 (MLX/Metal GPU)。BGM やノイズ混在音声向き。GPU を使うため ASR と直列実行。
/// - none: VAD を使わず Whisper に 30 秒ずつ直接渡す。音量差が激しいインタビュー動画向き。
enum VADMethod: String, Codable, CaseIterable {
    case energy
    case silero
    case none
}

/// VAD の検出感度。音源の特性に合わせてユーザーが選択する。
enum VADSensitivity: String, Codable, CaseIterable, Identifiable {
    case low
    case normal
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low:    return "低（誤検出を抑える）"
        case .normal: return "標準"
        case .high:   return "高（取りこぼしを減らす）"
        }
    }

    /// Silero VAD の onset 閾値。低いほど感度が高い。
    var sileroOnset: Float {
        switch self {
        case .low:    return 0.6
        case .normal: return 0.5
        case .high:   return 0.35
        }
    }

    /// Silero VAD の offset 閾値。
    var sileroOffset: Float {
        switch self {
        case .low:    return 0.4
        case .normal: return 0.35
        case .high:   return 0.25
        }
    }

    /// EnergyVAD の発話開始判定オフセット (dB)。ノイズフロアにこの値を加算した閾値を超えたら発話開始。
    var energyActivationOffsetDB: Float {
        switch self {
        case .low:    return 9.0
        case .normal: return 6.0
        case .high:   return 4.0
        }
    }

    /// EnergyVAD の発話終了判定オフセット (dB)。
    var energyDeactivationOffsetDB: Float {
        switch self {
        case .low:    return 5.0
        case .normal: return 3.0
        case .high:   return 2.0
        }
    }

    /// EnergyVAD のアクティベーション最低閾値 (dB)。
    var energyMinActivationDB: Float {
        switch self {
        case .low:    return -42.0
        case .normal: return -46.0
        case .high:   return -50.0
        }
    }

    /// EnergyVAD のデアクティベーション最低閾値 (dB)。
    var energyMinDeactivationDB: Float {
        switch self {
        case .low:    return -46.0
        case .normal: return -50.0
        case .high:   return -54.0
        }
    }

    /// EnergyVAD のハングオーバー（ms）。閾値を下回っても即座に無音判定せず、
    /// この期間は「まだ発話中」として扱う。息継ぎ・子音・声の揺れでの誤切断を防ぐ。
    var energyHangoverMs: Int {
        switch self {
        case .low:    return 400
        case .normal: return 300
        case .high:   return 200
        }
    }
}

// MARK: - VADCalibration

/// VAD キャリブレーション結果。ユーザーが「小さい声」「大きい声」の区間を指定して
/// 測定した RMS 値を保存する。EnergyVAD はこの値を基に閾値を決定する。
struct VADCalibration: Codable, Equatable {
    /// 小さい声（被写体）の RMS 値
    var quietRMS: Float
    /// 大きい声（インタビュアー）の RMS 値
    var loudRMS: Float

    /// 小さい声の RMS を基準に、それより少し低い値を deactivation 閾値にする
    var deactivationThreshold: Float {
        quietRMS * 0.6
    }

    /// 小さい声と大きい声の中間よりやや低めを activation 閾値にする
    var activationThreshold: Float {
        quietRMS * 0.8
    }
}

// MARK: - CaptionSettings

/// Caption トラックの共通設定。EditorState の一部として JSON に保存される。
struct CaptionSettings: Codable, Equatable {
    /// 主言語 (ISO 639-1 or "auto")。単一言語モードではこれだけ使う。
    var language: String = "ja"
    /// 追加言語。空なら単一言語モード、1つ以上あれば多言語マルチパスモード。
    /// 主言語 + 追加言語の各言語で STT を実行し、リージョンごとに最適な結果を採用する。
    var additionalLanguages: [String] = []
    /// この ms 以上の無音で強制分割する。
    var silenceSplitMs: Int = 350
    /// これ未満の duration を持つ segment は前後に merge する (無音境界は跨がない)。
    var minSegmentMs: Int = 500
    /// 空白区切り言語 (en 等) で 1 字幕に含める最大単語数。
    /// 英語は句点 `.` をそのまま分割境界にできない (略語・小数と曖昧) ため、
    /// 句点分割後にこの閾値で再分割する。CJK 言語では無視される。
    var maxWordsPerSegment: Int = 10
    /// ユーザー指定のドメインヒント (例: ["AI", "プログラミング"])。
    /// LLM 文脈推定のプロンプトに渡す。
    var domainHints: [String] = []
    /// 書き起こし後に辞書ベース置換を自動実行するか。
    var autoCorrectWithDictionary: Bool = true
    /// 書き起こし後に LLM 校正を自動実行するか。デフォルト: オフ。
    var autoCorrectWithLLM: Bool = false
    /// 長いリージョンをポスト分割するか。被せ喋りが多い動画では分割が破綻するためオフ推奨。
    var splitLongRegions: Bool = true
    /// 発話区間検出の方式。energy = CPU (高速/クリーン音声向き)、silero = GPU (BGM/ノイズ向き)。
    var vadMethod: VADMethod = .energy
    /// VAD の検出感度。
    var vadSensitivity: VADSensitivity = .normal
    /// VAD キャリブレーション結果。nil なら適応閾値を使う。
    var vadCalibration: VADCalibration?

    /// 多言語モードか（追加言語が1つ以上あるか）
    var isMultilingual: Bool { !additionalLanguages.isEmpty }

    /// STT で使う全言語リスト（主言語 + 追加言語）
    var allLanguages: [String] {
        var langs = [language]
        for lang in additionalLanguages where lang != language {
            langs.append(lang)
        }
        return langs
    }

    static let `default` = CaptionSettings()

    init() {}

    /// 既存 JSON との Codable 互換のため decodeIfPresent で読む。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language                 = try c.decodeIfPresent(String.self,           forKey: .language)                 ?? "ja"
        additionalLanguages      = try c.decodeIfPresent([String].self,         forKey: .additionalLanguages)      ?? []
        silenceSplitMs           = try c.decodeIfPresent(Int.self,              forKey: .silenceSplitMs)           ?? 350
        minSegmentMs             = try c.decodeIfPresent(Int.self,              forKey: .minSegmentMs)             ?? 500
        maxWordsPerSegment       = try c.decodeIfPresent(Int.self,              forKey: .maxWordsPerSegment)       ?? 10
        domainHints              = try c.decodeIfPresent([String].self,         forKey: .domainHints)              ?? []
        autoCorrectWithDictionary = try c.decodeIfPresent(Bool.self,            forKey: .autoCorrectWithDictionary) ?? true
        autoCorrectWithLLM        = try c.decodeIfPresent(Bool.self,            forKey: .autoCorrectWithLLM)        ?? false
        splitLongRegions          = try c.decodeIfPresent(Bool.self,            forKey: .splitLongRegions)          ?? true
        vadMethod                 = try c.decodeIfPresent(VADMethod.self,       forKey: .vadMethod)                 ?? .energy
        vadSensitivity            = try c.decodeIfPresent(VADSensitivity.self,  forKey: .vadSensitivity)            ?? .normal
        vadCalibration            = try c.decodeIfPresent(VADCalibration.self,  forKey: .vadCalibration)
    }

    private enum CodingKeys: String, CodingKey {
        case language, additionalLanguages, silenceSplitMs, minSegmentMs, maxWordsPerSegment
        case domainHints, autoCorrectWithDictionary, autoCorrectWithLLM, splitLongRegions, vadMethod, vadSensitivity, vadCalibration
    }
}

// MARK: - CaptionRenderStatus

/// Caption トラック全体の合成ステータス (UI 表示用)。
/// Region 単位ではなくトラック単位で進行する。
enum CaptionRenderStatus: Equatable {
    case idle
    /// 準備フェーズ全般 (音声ロード / VAD ロード+推論 / ASR ロード)。
    /// message が空なら汎用「モデル読み込み中」を表示する。
    case loadingModel(progress: Double, message: String = "")
    case transcribing(progress: Double)   // 0.0–1.0
    case correcting(phase: CorrectionPhase, progress: String)
    case failed(String)
}

/// 校正パイプラインのフェーズ。
enum CorrectionPhase: String, Equatable {
    case dictionary    // 辞書適用中
    case analyzing     // 文脈推定中
    case correcting    // LLM 校正中
}
