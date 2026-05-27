import Combine
import Foundation
import WebKit

/// YouTube IFrame Player API の状態を管理する。PlaybackController の YouTube 版。
@MainActor
final class YouTubePlayerController: NSObject, ObservableObject {

    static func intent() -> String {
        """
        役割: WKWebView 内の YouTube IFrame Player API との双方向通信を管理し、
        再生状態を SwiftUI に公開する ObservableObject。
        JS からの postMessage で currentTime / duration / playerState を受け取り、
        Swift 側から evaluateJavaScript で play / pause / seek を指示する。

        成熟度: experimental
        依存: YouTubeWebView が WKWebView インスタンスをセットする。

        変更時の注意:
        - loadVideo は WKWebView 生成前に呼ばれる可能性がある。
          pendingVideoID に保存し、onReady で自動ロードする。
        """
    }

    // MARK: - Published state

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying: Bool = false
    @Published var isReady: Bool = false
    @Published var videoTitle: String = ""
    @Published var videoID: String = ""
    @Published var errorMessage: String?

    // MARK: - WebView reference

    weak var webView: WKWebView?

    // MARK: - Pending load

    /// WebView が ready になる前に loadVideo が呼ばれた場合の保留 ID。
    private var pendingVideoID: String?
    /// URL の &t= パラメータから取得した初期シーク位置（秒）。
    private var pendingSeekSeconds: Double?

    // MARK: - Player control

    /// YouTube URL から動画をロードする。`&t=` 等の余計なパラメータは無視する。
    func loadFromURL(_ urlString: String) {
        guard let id = YouTubeURLValidator.extractVideoID(urlString) else {
            errorMessage = "有効な YouTube URL ではありません"
            return
        }
        loadVideo(id: id)
    }

    func loadVideo(id: String, seekTo: Double? = nil) {
        videoID = id
        errorMessage = nil
        pendingSeekSeconds = seekTo

        guard let webView else {
            pendingVideoID = id
            return
        }

        let urlStr = "https://www.youtube.com/watch?v=\(id)"
        guard let url = URL(string: urlStr) else { return }
        isReady = false
        webView.load(URLRequest(url: url))
    }

    func play() {
        webView?.evaluateJavaScript("document.querySelector('video')?.play()") { _, _ in }
    }

    func pause() {
        webView?.evaluateJavaScript("document.querySelector('video')?.pause()") { _, _ in }
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to seconds: Double) {
        webView?.evaluateJavaScript("var v=document.querySelector('video');if(v)v.currentTime=\(seconds)") { _, _ in }
    }
}

// MARK: - WKScriptMessageHandler

extension YouTubePlayerController: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        handleMessage(body)
    }

    private func handleMessage(_ body: [String: Any]) {
        guard let event = body["event"] as? String else { return }

        switch event {
        case "ready":
            isReady = true
            if let title = body["title"] as? String, !title.isEmpty {
                videoTitle = title
            }
            // 保留中の動画があればロードする
            if let pending = pendingVideoID {
                pendingVideoID = nil
                loadVideo(id: pending)
            }

        case "stateChange":
            if let state = body["state"] as? Int {
                isPlaying = (state == 1)
                // 動画が再生開始したら、保留中のシーク位置に飛ぶ（初回のみ）
                if state == 1, let seekTo = pendingSeekSeconds {
                    pendingSeekSeconds = nil
                    seek(to: seekTo)
                }
            }
            // タイトル取得（初回再生時）
            if let state = body["state"] as? Int, state == 1, videoTitle.isEmpty {
                webView?.evaluateJavaScript("document.title || ''") { [weak self] result, _ in
                    if let title = result as? String, !title.isEmpty {
                        self?.videoTitle = title
                    }
                }
            }

        case "timeUpdate":
            if let time = body["currentTime"] as? Double {
                currentTime = time
            }
            if let dur = body["duration"] as? Double, dur > 0 {
                duration = dur
            }

        case "error":
            let code = body["code"] as? Int ?? -1
            switch code {
            case 2:   errorMessage = "無効な動画IDです"
            case 5:   errorMessage = "HTML5 プレーヤーエラー"
            case 100:  errorMessage = "動画が見つかりません（削除済み or 非公開）"
            case 101, 150: errorMessage = "この動画は埋め込み再生が許可されていません"
            default:  errorMessage = "YouTube エラー (コード: \(code))"
            }

        case "mediaDebug":
            let mediaEvent = body["mediaEvent"] as? String ?? "?"
            let dur = body["duration"] as? Double ?? 0
            let time = body["currentTime"] as? Double ?? 0
            let srcChanged = body["srcChanged"] as? Bool ?? false
            let readyState = body["readyState"] as? Int ?? -1
            NSLog("[YT-MediaDebug] %@ | duration=%.1f currentTime=%.1f srcChanged=%d readyState=%d", mediaEvent, dur, time, srcChanged ? 1 : 0, readyState)

        default:
            break
        }
    }
}
