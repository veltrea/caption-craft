import Foundation

/// CaptionCraft プロジェクト。
struct CaptionCraftProject: Codable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var id: UUID = UUID()
    var name: String = "Untitled"
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var media: MediaPaths
    var editor: EditorState
}

/// プロジェクトが扱うメディアファイルのパス情報。
///
/// CC Phase 03 で `webcamVideoPath` / `systemAudioPath` / `micAudioPath` /
/// `cursorTelemetryPath` / `originalWidth` / `originalHeight` を削除した。
/// CaptionCraft は単一動画ファイルから字幕を生成するため、`screenVideoPath` だけで
/// メディア入力を表せる。フィールド名 `screenVideoPath` は旧プロジェクトファイルとの
/// Codable 互換のため変更しない (CC Phase 05 で `videoPath` 等に改名候補)。
struct MediaPaths: Codable {
    /// 動画ファイルの絶対パス。新規プロジェクトでは Open したファイルの URL、
    /// プロジェクトパッケージから読み込まれた場合は package 相対パスから絶対化された値。
    var screenVideoPath: String

    /// プロジェクト作成日時 (旧プロジェクトとの互換のため残置)。
    var createdAt: Date = Date()

    /// 動画長 (ms)。AVURLAsset から AVPlayer ロード時に算出されて書き戻される。
    var durationMs: Int = 0

    // MARK: - YouTube モード

    /// YouTube 動画の URL。non-nil のとき YouTube モードとして動作する。
    var youtubeURL: String?

    /// ScreenCaptureKit でキャプチャした音声 WAV ファイルのパス。
    var capturedAudioPath: String?

    /// キャプチャ開始時の YouTube 再生位置 (ms)。STT 結果のタイムスタンプにオフセットとして加算する。
    var captureOffsetMs: Int = 0

    /// YouTube モードかどうか。
    var isYouTubeMode: Bool { youtubeURL != nil }

    init(
        screenVideoPath: String,
        createdAt: Date = Date(),
        durationMs: Int = 0,
        youtubeURL: String? = nil,
        capturedAudioPath: String? = nil,
        captureOffsetMs: Int = 0
    ) {
        self.screenVideoPath = screenVideoPath
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.youtubeURL = youtubeURL
        self.capturedAudioPath = capturedAudioPath
        self.captureOffsetMs = captureOffsetMs
    }

    /// 旧プロジェクトとの互換のため `decodeIfPresent` で読み、
    /// 削除済みフィールドは無視する。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenVideoPath  = try c.decodeIfPresent(String.self, forKey: .screenVideoPath) ?? ""
        createdAt        = try c.decodeIfPresent(Date.self,   forKey: .createdAt)        ?? Date()
        durationMs       = try c.decodeIfPresent(Int.self,    forKey: .durationMs)       ?? 0
        youtubeURL       = try c.decodeIfPresent(String.self, forKey: .youtubeURL)
        capturedAudioPath = try c.decodeIfPresent(String.self, forKey: .capturedAudioPath)
        captureOffsetMs  = try c.decodeIfPresent(Int.self,    forKey: .captureOffsetMs)  ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case screenVideoPath
        case createdAt
        case durationMs
        case youtubeURL
        case capturedAudioPath
        case captureOffsetMs
    }
}
