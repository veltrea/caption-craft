import AppKit
import Foundation

// MARK: - LLMClient

/// OpenAI Chat Completions 互換 API の共通クライアント。
/// TranslationService と CorrectionService が共用する。
///
/// 成熟度: experimental
struct LLMClient {

    static func intent() -> String {
        """
        役割: OpenAI Chat Completions 互換エンドポイントへのリクエスト送信。
              LM Studio / Ollama 等のローカル LLM に対応。
              TranslationService と CorrectionService で共用。
        成熟度: experimental
        依存: URLSession (Foundation)
        変更時の注意: レスポンス JSON の構造は OpenAI 互換仕様に準拠。
        """
    }

    let endpoint: URL

    init(endpoint: URL = URL(string: "http://localhost:1234")!) {
        self.endpoint = endpoint
    }

    /// /v1/models からロード済みモデル一覧を取得する。
    func fetchModels() async throws -> [LLMModelInfo] {
        let url = endpoint.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.networkError(L10n.Error.unknownResponse)
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.apiError(httpResponse.statusCode, String(body.prefix(300)))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]]
        else {
            throw LLMClientError.parseError(L10n.Error.modelListParse)
        }

        return dataArray.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return LLMModelInfo(id: id)
        }
    }

    /// Chat Completions API を呼び出し、assistant メッセージの content を返す。
    ///
    /// `jsonSchema` を渡すと OpenAI 互換の Structured Output (response_format=json_schema)
    /// を指定する。LM Studio 0.3+ で動作。granite-tiny でも検証済み。
    func chatCompletion(
        system: String,
        user: String,
        model: String? = nil,
        temperature: Double = 0.3,
        maxTokens: Int = 4096,
        jsonSchema: [String: Any]? = nil,
        jsonSchemaName: String = "response"
    ) async throws -> String {
        var requestBody: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": temperature,
            "max_tokens": maxTokens
        ]
        if let model { requestBody["model"] = model }
        if let jsonSchema {
            requestBody["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": jsonSchemaName,
                    "strict": true,
                    "schema": jsonSchema
                ]
            ]
        }

        let url = endpoint.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.networkError(L10n.Error.unknownResponse)
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.apiError(httpResponse.statusCode, String(body.prefix(300)))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMClientError.parseError(L10n.Error.responseParse)
        }

        return content
    }

    /// LM Studio にモデルのロードをリクエストする。
    /// LM Studio 0.3+ の /api/v0/models/load を使用。
    func loadModel(id: String) async throws {
        let url = endpoint.appendingPathComponent("api/v0/models/load")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": id
        ])
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.networkError(L10n.Error.unknownResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.apiError(httpResponse.statusCode, String(body.prefix(300)))
        }
    }
}

// MARK: - LLMModelInfo

struct LLMModelInfo: Identifiable, Hashable {
    let id: String
}

// MARK: - LLMServerStatus

/// LLM サーバーの接続状態。UI 分岐に使う。
enum LLMServerStatus: Equatable {
    /// LM Studio がインストールされていない
    case notInstalled
    /// LM Studio はインストール済みだが起動していない（ポート応答なし）
    case notRunning
    /// サーバーは応答するがモデルが読み込まれていない
    case noModelLoaded
    /// 接続済み・モデルあり
    case connected(modelCount: Int)

    var isUsable: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - LLMServerChecker

/// LM Studio のインストール・起動・モデル状態を検出する。
enum LLMServerChecker {

    /// LM Studio.app がインストールされているかチェック
    static var isLMStudioInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/LM Studio.app")
    }

    /// LM Studio.app を起動する
    @MainActor
    static func launchLMStudio() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "ai.lmstudio"
        ) else {
            // バンドル ID で見つからない場合はパスで起動
            let appURL = URL(fileURLWithPath: "/Applications/LM Studio.app")
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: .init(),
                completionHandler: nil
            )
            return
        }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: .init(),
            completionHandler: nil
        )
    }

    /// エンドポイントに接続してサーバー状態を判定する
    static func checkStatus(endpoint: URL) async -> LLMServerStatus {
        // 1. LM Studio がインストールされているか（デフォルトエンドポイントの場合のみ）
        let isDefaultEndpoint = endpoint.host == "localhost" || endpoint.host == "127.0.0.1"
        if isDefaultEndpoint && !isLMStudioInstalled {
            return .notInstalled
        }

        // 2. サーバーが応答するか
        let client = LLMClient(endpoint: endpoint)
        do {
            let models = try await client.fetchModels()
            if models.isEmpty {
                return .noModelLoaded
            }
            return .connected(modelCount: models.count)
        } catch {
            if isDefaultEndpoint && isLMStudioInstalled {
                return .notRunning
            }
            // カスタムエンドポイントの場合は notRunning 扱い
            return .notRunning
        }
    }
}

// MARK: - LLMClientError

enum LLMClientError: LocalizedError {
    case networkError(String)
    case apiError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg):
            return L10n.Error.network(msg)
        case .apiError(let code, let body):
            return L10n.Error.api(code, body)
        case .parseError(let msg):
            return L10n.Error.parse(msg)
        }
    }
}
