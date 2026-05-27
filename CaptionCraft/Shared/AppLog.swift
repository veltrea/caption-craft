import Foundation
import os

// MARK: - AppLog

/// CaptionCraft 全体のロガー集約。
///
/// 成熟度: experimental
///
/// 使い方:
/// ```swift
/// AppLog.caption.info("Whisper prepare 開始 size=\(size.rawValue)")
/// AppLog.caption.error("DL 失敗: \(error.localizedDescription)")
/// AppLog.transcribe.debug("segments=\(raw.count)")
/// ```
///
/// 出力先:
/// - Console.app (subsystem `com.veltrea.captioncraft` で絞れる)
/// - `log show --process CaptionCraft --last 5m`
/// - `log stream --process CaptionCraft --level debug`
///
/// Debug ビルドでは stdout にも吐く (Xcode Run / open -n のターミナル両方で見える)。
enum AppLog {

    private static let subsystem = "com.veltrea.captioncraft"

    /// アプリ起動 / メニュー / ウィンドウ制御。
    static let app         = Logger(subsystem: subsystem, category: "app")

    /// 字幕パイプライン全般 (Whisper モデル管理含む)。
    static let caption     = Logger(subsystem: subsystem, category: "caption")

    /// 文字起こし実行 (CaptionTranscriber の状態遷移)。
    static let transcribe  = Logger(subsystem: subsystem, category: "transcribe")

    /// 翻訳サービス (LLM 通信)。
    static let translation = Logger(subsystem: subsystem, category: "translation")

    /// SRT 等の字幕フォーマット I/O。
    static let srt         = Logger(subsystem: subsystem, category: "srt")

    /// ファイル I/O / プロジェクト保存。
    static let file        = Logger(subsystem: subsystem, category: "file")

    /// 再生制御。
    static let playback    = Logger(subsystem: subsystem, category: "playback")

    /// 校正パイプライン (辞書 / LLM)。
    static let correction  = Logger(subsystem: subsystem, category: "correction")
}
