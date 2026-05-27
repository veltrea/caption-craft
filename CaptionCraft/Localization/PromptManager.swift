import Foundation

// MARK: - PromptManager

/// AI プロンプトを外部 JSON から読み込み、変数を展開して返す。
/// JSON は Resources/Prompts/ に格納し、{{variable}} をランタイムで置換する。
///
/// 成熟度: experimental
enum PromptManager {

    static func intent() -> String {
        """
        役割: correction_prompts.json / translation_prompts.json から
              AI 向けプロンプトテンプレートを読み込み、変数展開して返す。
        成熟度: experimental
        依存: Resources/Prompts/*.json
        変更時の注意: JSON のキー構造を変えたら対応する Swift 側アクセサも更新すること。
        """
    }

    // MARK: - Correction Prompts

    enum Correction {
        static func contextInferenceSystem() -> String {
            load(file: "correction_prompts", keyPath: ["contextInference", "system"])
        }

        static func contextInferenceUser(transcription: String, hints: String) -> String {
            let template = load(file: "correction_prompts", keyPath: ["contextInference", "user"])
            return render(template, vars: [
                "transcription": transcription,
                "hints": hints
            ])
        }

        static func batchCorrectionSystem(domain: String, keyTerms: String, dictSection: String, language: String = "日本語") -> String {
            let template = load(file: "correction_prompts", keyPath: ["batchCorrection", "system"])
            return render(template, vars: [
                "domain": domain,
                "keyTerms": keyTerms,
                "dictSection": dictSection,
                "language": language
            ])
        }
    }

    // MARK: - Translation Prompts

    enum Translation {
        /// 1件ずつ JSON {"source","translation"} で受け取るためのシステムプロンプト。
        /// 軽量モデル (granite-tiny 等) でも圧縮統合を起こさせない設計。
        static func pairSystem(fromLang: String, targetLang: String) -> String {
            let template = load(file: "translation_prompts", keyPath: ["pair", "system"])
            return render(template, vars: [
                "fromLang": fromLang,
                "targetLang": targetLang
            ])
        }
    }

    // MARK: - Internal

    private static var cache: [String: [String: Any]] = [:]

    private static func load(file: String, keyPath: [String]) -> String {
        let dict = loadJSON(file)
        var current: Any = dict
        for key in keyPath {
            guard let next = (current as? [String: Any])?[key] else {
                assertionFailure("PromptManager: キー \(keyPath.joined(separator: ".")) が \(file).json に見つかりません")
                return ""
            }
            current = next
        }
        return current as? String ?? ""
    }

    private static func loadJSON(_ file: String) -> [String: Any] {
        if let cached = cache[file] { return cached }

        guard let url = Bundle.main.url(forResource: file, withExtension: "json", subdirectory: nil) ??
                        Bundle.main.url(forResource: file, withExtension: "json") else {
            assertionFailure("PromptManager: \(file).json がバンドルに見つかりません")
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            cache[file] = json
            return json
        } catch {
            assertionFailure("PromptManager: \(file).json の読み込みに失敗: \(error)")
            return [:]
        }
    }

    private static func render(_ template: String, vars: [String: String]) -> String {
        var result = template
        for (key, value) in vars {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}
