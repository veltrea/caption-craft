import Foundation

// MARK: - TranslationService

/// ローカル LLM (LM Studio / Ollama 等の OpenAI 互換 API) を使った字幕翻訳サービス。
///
/// 成熟度: experimental
///
/// 設計:
/// - OpenAI Chat Completions 互換エンドポイント (POST /v1/chat/completions) を叩く
/// - デフォルトは localhost:1234 (LM Studio)
/// - 字幕を一括でプロンプトに渡し、行番号付きで翻訳結果を返させる
/// - レスポンスをパースして CaptionRegion の text を差し替える
@MainActor
final class TranslationService: ObservableObject {

    static func intent() -> String {
        """
        役割: CaptionRegion 配列のテキストをローカル LLM で翻訳する。
        成熟度: experimental
        依存: CaptionRegion, URLSession (Foundation)
        変更時の注意: OpenAI Chat Completions API 互換のレスポンス形式に依存。
                     LM Studio / Ollama 共通で動く。
        """
    }

    // MARK: - Published state

    @Published var isTranslating: Bool = false
    @Published var progress: String = ""
    @Published var lastError: String?

    // MARK: - Settings

    /// LLM API のベース URL。LM Studio のデフォルトは localhost:1234。
    /// LLMClient と共有する設定。
    @Published var endpoint: URL = URL(string: "http://localhost:1234")! {
        didSet { refreshModels() }
    }

    /// サーバーで利用可能なモデル一覧
    @Published var availableModels: [LLMModelInfo] = []

    /// 選択中のモデル ID（nil ならサーバーのデフォルトを使用）
    @Published var selectedModelID: String? = UserDefaults.standard.string(forKey: "cc_translationModel") {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "cc_translationModel") }
    }

    /// モデル一覧を取得中かどうか
    @Published var isFetchingModels: Bool = false

    /// サーバーの接続状態
    @Published var serverStatus: LLMServerStatus = .notRunning

    /// 自動ロード中かどうか
    @Published var isAutoLoading: Bool = false

    /// UserDefaults に保存済みのモデル ID（サーバー未接続時でも参照できる）
    var savedModelID: String? {
        UserDefaults.standard.string(forKey: "cc_translationModel")
    }

    private var llmClient: LLMClient {
        LLMClient(endpoint: endpoint)
    }

    /// サーバー状態を検出し、モデル一覧を取得する
    func refreshModels() {
        isFetchingModels = true
        Task {
            let status = await LLMServerChecker.checkStatus(endpoint: endpoint)
            await MainActor.run {
                self.serverStatus = status
                switch status {
                case .connected:
                    break
                case .noModelLoaded:
                    self.availableModels = []
                    self.isFetchingModels = false
                    // 保存済みモデルがあれば自動ロードを試みる
                    if let modelID = savedModelID {
                        autoLoadModel(id: modelID)
                    }
                    return
                case .notInstalled, .notRunning:
                    self.availableModels = []
                    self.isFetchingModels = false
                    return
                }
            }
            // connected の場合のみモデル一覧を取得
            await fetchAndApplyModels()
        }
    }

    /// 保存済みモデルを LM Studio に自動ロードする
    func autoLoadModel(id: String) {
        guard !isAutoLoading else { return }
        isAutoLoading = true
        AppLog.translation.info("モデル自動ロード開始: \(id, privacy: .public)")
        Task {
            do {
                try await llmClient.loadModel(id: id)
                AppLog.translation.info("モデル自動ロード成功: \(id, privacy: .public)")
                // ロード成功 → モデル一覧を再取得して connected に遷移
                await fetchAndApplyModels()
                await MainActor.run {
                    self.serverStatus = .connected(modelCount: self.availableModels.count)
                    self.isAutoLoading = false
                }
            } catch {
                AppLog.translation.warning("モデル自動ロード失敗: \(error.localizedDescription)")
                await MainActor.run {
                    self.isAutoLoading = false
                }
            }
        }
    }

    private func fetchAndApplyModels() async {
        do {
            let models = try await llmClient.fetchModels()
            await MainActor.run {
                self.availableModels = models
                if let selected = selectedModelID,
                   !models.contains(where: { $0.id == selected }) {
                    self.selectedModelID = models.first?.id
                }
                if selectedModelID == nil, let first = models.first {
                    self.selectedModelID = first.id
                }
                self.isFetchingModels = false
            }
        } catch {
            await MainActor.run {
                self.availableModels = []
                self.isFetchingModels = false
                AppLog.translation.warning("モデル一覧の取得に失敗: \(error.localizedDescription)")
            }
        }
    }

    /// 翻訳先言語（UserDefaults に保存して次回起動時に復元）
    @Published var targetLanguage: String = UserDefaults.standard.string(forKey: "cc_translationTargetLang") ?? "en" {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "cc_translationTargetLang") }
    }

    /// 翻訳元言語 (空なら自動判定を LLM に任せる)
    @Published var sourceLanguage: String = ""

    // MARK: - Translation

    /// JSON Schema 強制出力で 1 件だけ翻訳する。
    /// 軽量モデルでも圧縮統合が発生しないよう、リクエスト単位を 1 件に固定し、
    /// LLM には `{"source","translation"}` の 2 フィールド JSON を返させる。
    ///
    /// 字幕は文の途中で切れる (例: "well done. Why does") ため、TARGET 単独だと
    /// 意味が取れず LLM 出力品質が落ちる。`prevContext` と `nextContext` で前後を
    /// 補助情報として渡し、TARGET だけを訳させる構造プロンプトを使う。
    /// 戻り値が nil の場合は翻訳失敗 (生応答は ACPLogStore に記録)。
    private func translateOne(
        _ region: CaptionRegion,
        prevContext: [CaptionRegion],
        nextContext: [CaptionRegion],
        regionIndex: Int? = nil
    ) async throws -> String? {
        let fromLang = sourceLanguage.isEmpty ? "the source language" : sourceLanguage
        let systemPrompt = PromptManager.Translation.pairSystem(
            fromLang: fromLang,
            targetLang: targetLanguage
        )

        // ユーザープロンプトを CONTEXT BEFORE / TARGET / CONTEXT AFTER で構造化。
        // CONTEXT が空のときはセクション自体を出さない (LLM が「無い」と誤解しないよう)。
        var sections: [String] = []
        if !prevContext.isEmpty {
            let lines = prevContext.map { "- \($0.text)" }.joined(separator: "\n")
            sections.append("CONTEXT BEFORE:\n\(lines)")
        }
        sections.append("TARGET:\n\(region.text)")
        if !nextContext.isEmpty {
            let lines = nextContext.map { "- \($0.text)" }.joined(separator: "\n")
            sections.append("CONTEXT AFTER:\n\(lines)")
        }
        let userPrompt = sections.joined(separator: "\n\n")

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "source": ["type": "string"],
                "translation": ["type": "string"]
            ],
            "required": ["source", "translation"],
            "additionalProperties": false
        ]

        let content: String
        do {
            content = try await llmClient.chatCompletion(
                system: systemPrompt,
                user: userPrompt,
                model: selectedModelID,
                temperature: 0.3,
                maxTokens: 2048,
                jsonSchema: schema,
                jsonSchemaName: "translation"
            )
        } catch let error as LLMClientError {
            switch error {
            case .networkError(let msg): throw TranslationError.networkError(msg)
            case .apiError(let code, let body): throw TranslationError.apiError(code, body)
            case .parseError(let msg): throw TranslationError.parseError(msg)
            }
        }

        let idxTag = regionIndex.map { "[\($0)] " } ?? ""

        // JSON パース失敗時は生応答を ACPLogStore に記録 (原因追跡用)。
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translation = obj["translation"] as? String
        else {
            AppLog.translation.warning("\(idxTag, privacy: .public)JSON パース失敗: \(content.prefix(300), privacy: .public)")
            ACPLogStore.shared.append(
                category: "translation", level: "warn",
                message: "\(idxTag)JSONパース失敗 原文='\(String(region.text.prefix(60)))' 生応答='\(String(content.prefix(300)))'"
            )
            return nil
        }

        // source 検証 (LLM が context の方を訳してしまった等の混同を検出)。
        if let source = obj["source"] as? String {
            let srcPrefix = source.prefix(30)
            let origPrefix = region.text.prefix(30)
            if srcPrefix != origPrefix {
                AppLog.translation.warning("\(idxTag, privacy: .public)source 不一致: 原文='\(region.text.prefix(40), privacy: .public)' LLM返却='\(source.prefix(40), privacy: .public)'")
                ACPLogStore.shared.append(
                    category: "translation", level: "warn",
                    message: "\(idxTag)source不一致: 原文='\(String(region.text.prefix(40)))' ≠ LLM='\(String(source.prefix(40)))'"
                )
            }
        }

        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ACPLogStore.shared.append(
                category: "translation", level: "warn",
                message: "\(idxTag)translation空 原文='\(String(region.text.prefix(60)))' 生応答='\(String(content.prefix(300)))'"
            )
            return nil
        }
        return trimmed
    }

    /// 指定インデックス周辺の前後 `radius` 件を切り出す。
    private static func sliceContext(
        regions: [CaptionRegion],
        index: Int,
        radius: Int
    ) -> (prev: [CaptionRegion], next: [CaptionRegion]) {
        let prevLo = max(0, index - radius)
        let prevHi = index
        let nextLo = index + 1
        let nextHi = min(regions.count, index + 1 + radius)
        let prev = prevLo < prevHi ? Array(regions[prevLo..<prevHi]) : []
        let next = nextLo < nextHi ? Array(regions[nextLo..<nextHi]) : []
        return (prev, next)
    }

    /// 単一リージョンを翻訳する。UI のリージョン単発翻訳ボタンから呼ばれる。
    /// allRegions から前後 2 件をコンテキストとして自動切り出し。
    func translateSingle(
        _ region: CaptionRegion,
        context allRegions: [CaptionRegion]
    ) async throws -> CaptionRegion {
        isTranslating = true
        lastError = nil
        progress = L10n.Progress.translating
        defer { isTranslating = false; progress = "" }

        let idx = allRegions.firstIndex(where: { $0.id == region.id }) ?? 0
        let (prev, next) = Self.sliceContext(regions: allRegions, index: idx, radius: 2)

        guard let translated = try await translateOne(
            region, prevContext: prev, nextContext: next, regionIndex: idx
        ) else {
            return region
        }
        var updated = region
        updated.translatedText = translated
        updated.translatedLanguage = targetLanguage
        return updated
    }

    /// 字幕配列を 1 件ずつ JSON Schema 強制で翻訳する。
    /// 時間情報はそのまま維持し、translatedText に翻訳を格納する。
    /// onBatchDone は 1 件完了ごとに「ここまでの累積結果 + 未処理分の原文」を返す。
    /// 呼び出し元はこれを使って画面をインクリメンタルに更新できる。
    func translate(
        _ regions: [CaptionRegion],
        onBatchDone: (([CaptionRegion]) -> Void)? = nil
    ) async throws -> [CaptionRegion] {
        guard !regions.isEmpty else { return [] }

        AppLog.translation.info("翻訳開始: \(regions.count) entries → \(self.targetLanguage, privacy: .public) endpoint=\(self.endpoint.absoluteString, privacy: .public)")
        ACPLogStore.shared.append(
            category: "translation", level: "info",
            message: "翻訳開始: \(regions.count) entries → \(targetLanguage)"
        )
        isTranslating = true
        lastError = nil
        progress = L10n.Progress.translatingCount(done: 0, total: regions.count)
        defer { isTranslating = false }

        // 前回の翻訳結果をクリアしてから始める。
        // クリアしないと translateOne が失敗した箇所に古い翻訳が残り、
        // 「翻訳に失敗したのに成功したように見える」状態が発生する。
        var translated: [CaptionRegion] = regions.map { region in
            var r = region
            r.translatedText = nil
            r.translatedLanguage = nil
            return r
        }
        var successCount = 0
        let startedAt = Date()

        for (i, region) in regions.enumerated() {
            let (prev, next) = Self.sliceContext(regions: regions, index: i, radius: 2)
            let result = try await translateOne(
                region, prevContext: prev, nextContext: next, regionIndex: i
            )
            if let result {
                translated[i].translatedText = result
                translated[i].translatedLanguage = targetLanguage
                successCount += 1
            } else {
                AppLog.translation.warning("リージョン \(i) の翻訳失敗 (translatedText=nil)")
                ACPLogStore.shared.append(
                    category: "translation", level: "warn",
                    message: "リージョン \(i) 翻訳失敗 (詳細は直前の warn を参照)"
                )
            }
            progress = L10n.Progress.translatingCount(done: i + 1, total: regions.count)
            onBatchDone?(translated)
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        AppLog.translation.info("翻訳完了: \(successCount)/\(regions.count) entries, \(String(format: "%.1f", elapsed))s")
        ACPLogStore.shared.append(
            category: "translation", level: "info",
            message: "翻訳完了: \(successCount)/\(regions.count) entries, \(String(format: "%.1f", elapsed))s"
        )
        progress = L10n.Progress.done
        return translated
    }
}

// MARK: - TranslationError

enum TranslationError: LocalizedError {
    case networkError(String)
    case apiError(Int, String)
    case parseError(String)
    case noLLMAvailable

    var errorDescription: String? {
        switch self {
        case .networkError(let msg):
            return L10n.Error.network(msg)
        case .apiError(let code, let body):
            return L10n.Error.api(code, String(body.prefix(200)))
        case .parseError(let msg):
            return L10n.Error.parse(msg)
        case .noLLMAvailable:
            return L10n.Error.noLLM
        }
    }
}
