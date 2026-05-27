import CoreGraphics
import Foundation

/// CaptionCraft プロジェクトのエディタ状態。
///
/// CC Phase 03 で動画編集機能 (Annotation / BGM / Keystroke / Mouse / Narration / TTS /
/// Zoom / Trim / Speed / Webcam / Cursor / Animation / Background) を全削除した結果、
/// 字幕作成に必要な最小フィールドだけが残っている。
///
/// Codable 互換: 旧プロジェクトファイルを開けるよう、削除された
/// フィールドは `decodeIfPresent` で読み飛ばして無視する。逆に Caption 関連の
/// 新規フィールドが既存 JSON にない場合もデフォルト値で埋める。
struct EditorState: Codable {
    /// 動画プレビューの表示縦横比。
    /// 入力動画の解像度から自動推定される値が初期値として使われる。
    var aspectRatio: AspectRatio = .widescreen

    /// 字幕区間の配列。Whisper 自動合成または手動編集で作成・更新される。
    var captionRegions: [CaptionRegion] = []

    /// 字幕トラック共通設定 (Whisper モデル / 言語 / 分割閾値)。
    var captionSettings: CaptionSettings = .default

    init() {}

    /// Codable 自前実装。
    /// 旧プロジェクトとの互換のため `decodeIfPresent` で読み、
    /// 削除済みフィールドは無視する。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspectRatio     = try c.decodeIfPresent(AspectRatio.self,     forKey: .aspectRatio)     ?? .widescreen
        captionRegions  = try c.decodeIfPresent([CaptionRegion].self, forKey: .captionRegions)  ?? []
        captionSettings = try c.decodeIfPresent(CaptionSettings.self, forKey: .captionSettings) ?? .default
    }

    private enum CodingKeys: String, CodingKey {
        case aspectRatio
        case captionRegions
        case captionSettings
    }
}

// MARK: - AspectRatio

enum AspectRatio: String, Codable, CaseIterable {
    case widescreen    = "16:9"
    case portrait      = "9:16"
    case standard      = "4:3"
    case portraitStd   = "3:4"
    case square        = "1:1"
    case ultraWide     = "21:9"
    case ultraPortrait = "9:21"
    case custom

    var cgSize: CGSize {
        switch self {
        case .widescreen:    return CGSize(width: 16, height: 9)
        case .portrait:      return CGSize(width: 9, height: 16)
        case .standard:      return CGSize(width: 4, height: 3)
        case .portraitStd:   return CGSize(width: 3, height: 4)
        case .square:        return CGSize(width: 1, height: 1)
        case .ultraWide:     return CGSize(width: 21, height: 9)
        case .ultraPortrait: return CGSize(width: 9, height: 21)
        case .custom:        return CGSize(width: 16, height: 9)
        }
    }
}

// MARK: - Geometry helpers

/// 字幕プレビューや動画フレームの座標計算に使われる正規化矩形。
/// CC Phase 03 削減後も `BackgroundStyle` などの一部 UI ヘルパで参照される
/// 可能性があるため型は維持する (実際のフィールドはほぼ未使用)。
struct NormalizedRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct NormalizedPoint: Codable, Equatable {
    var cx: Double
    var cy: Double
}
