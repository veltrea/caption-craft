import Foundation
import SwiftUI

/// アプリ全体の設定値を保持する ObservableObject。
///
/// Whisper 設定 (言語 / 無音閾値 / 最大単語数) を UserDefaults に保存し、
/// 新規プロジェクトを開いたときに前回の設定値を自動復元する。
@MainActor
final class PreferencesStore: ObservableObject {

    static func intent() -> String {
        return """
        役割: CaptionCraft 全体の UserDefaults 背景付き設定値を集約する store。
        Settings ウィンドウの各 Pane が参照する。

        成熟度: experimental

        変更時の注意:
        - プロパティ追加時は `Keys` に対応する UserDefaults キーを定義し、
          `init()` で読み込み、didSet で書き戻す 3 点セットを必ずそろえる。
        - @MainActor 前提。バックグラウンドスレッドから直接プロパティ更新しない。
        - キー文字列を変更するとユーザーの設定が消えるので、いったん配線したキーは
          原則変更しない (CaptionCraft.preferences.*.v1 のように versioning を含めておく)。
        """
    }

    static let shared = PreferencesStore()

    private let ud = UserDefaults.standard

    // MARK: - UserDefaults keys

    private enum Keys {
        static let whisperLanguage     = "CaptionCraft.preferences.whisperLanguage.v1"
        static let silenceSplitMs      = "CaptionCraft.preferences.silenceSplitMs.v1"
        static let maxWordsPerSegment  = "CaptionCraft.preferences.maxWordsPerSegment.v1"
        static let sttEngine           = "CaptionCraft.preferences.sttEngine.v1"
        static let whisperModelVariant = "CaptionCraft.preferences.whisperModelVariant.v1"
    }

    // MARK: - Whisper settings

    @Published var whisperLanguage: String {
        didSet { ud.set(whisperLanguage, forKey: Keys.whisperLanguage) }
    }

    @Published var silenceSplitMs: Int {
        didSet { ud.set(silenceSplitMs, forKey: Keys.silenceSplitMs) }
    }

    @Published var maxWordsPerSegment: Int {
        didSet { ud.set(maxWordsPerSegment, forKey: Keys.maxWordsPerSegment) }
    }

    // MARK: - STT engine selection

    /// 主 STT エンジン。動画全体の文字起こしに使われる。
    /// 副エンジン (他のエンジン) はオンデマンドのクロスチェックに使う。
    @Published var sttEngine: STTEngineType {
        didSet { ud.set(sttEngine.rawValue, forKey: Keys.sttEngine) }
    }

    /// Whisper モデルバリアント。主エンジンが Whisper のときに使用するモデルサイズ。
    @Published var whisperModelVariant: WhisperModelVariant {
        didSet { ud.set(whisperModelVariant.rawValue, forKey: Keys.whisperModelVariant) }
    }

    /// UserDefaults に Whisper 設定が 1 つでも保存されているか。
    var hasStoredWhisperSettings: Bool {
        ud.object(forKey: Keys.whisperLanguage) != nil
    }

    // MARK: - Init

    private init() {
        let defaults = CaptionSettings.default

        if let lang = ud.string(forKey: Keys.whisperLanguage) {
            whisperLanguage = lang
        } else {
            whisperLanguage = defaults.language
        }

        let storedSilence = ud.integer(forKey: Keys.silenceSplitMs)
        silenceSplitMs = storedSilence != 0 ? storedSilence : defaults.silenceSplitMs

        let storedWords = ud.integer(forKey: Keys.maxWordsPerSegment)
        maxWordsPerSegment = storedWords != 0 ? storedWords : defaults.maxWordsPerSegment

        // STT エンジン。デフォルトは Whisper (汎用、日本語対応)。
        if let rawValue = ud.string(forKey: Keys.sttEngine),
           let engine = STTEngineType(rawValue: rawValue) {
            sttEngine = engine
        } else {
            sttEngine = .whisper
        }

        // Whisper モデルバリアント。デフォルトは turbo (精度と速度のバランス)。
        if let rawValue = ud.string(forKey: Keys.whisperModelVariant),
           let variant = WhisperModelVariant(rawValue: rawValue) {
            whisperModelVariant = variant
        } else {
            whisperModelVariant = .turbo
        }
    }

    // MARK: - Bulk operations

    /// CaptionSettings からまとめて保存する。
    func saveWhisperSettings(_ s: CaptionSettings) {
        whisperLanguage = s.language
        silenceSplitMs = s.silenceSplitMs
        maxWordsPerSegment = s.maxWordsPerSegment
    }

    /// 保存済み設定を CaptionSettings として返す。
    func loadWhisperSettings() -> CaptionSettings {
        var s = CaptionSettings()
        s.language = whisperLanguage
        s.silenceSplitMs = silenceSplitMs
        s.maxWordsPerSegment = maxWordsPerSegment
        return s
    }

    // MARK: - Reset

    func resetAll() {
        let defaults = CaptionSettings.default
        whisperLanguage = defaults.language
        silenceSplitMs = defaults.silenceSplitMs
        maxWordsPerSegment = defaults.maxWordsPerSegment
        sttEngine = .whisper
        whisperModelVariant = .turbo
    }
}
