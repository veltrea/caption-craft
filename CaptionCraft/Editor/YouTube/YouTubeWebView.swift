import SwiftUI
import WebKit

/// YouTube のページを直接表示する WKWebView。
/// IFrame API ではなくページ内の <video> 要素から再生状態を取得する。
struct YouTubeWebView: NSViewRepresentable {

    static func intent() -> String {
        """
        役割: YouTube の動画ページを直接ナビゲートして表示する WKWebView。
        IFrame API の埋め込み制限 (エラー 150/152) を回避するため、
        YouTube ページ自体に遷移し、ページ内の <video> 要素を JS で監視する。

        成熟度: experimental
        依存: YouTubePlayerController が WKScriptMessageHandler として登録される。
        """
    }

    @ObservedObject var controller: YouTubePlayerController

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.mediaTypesRequiringUserActionForPlayback = []

        // JS→Swift メッセージハンドラ登録
        config.userContentController.add(controller, name: "ytState")

        // YouTube ページロード完了後に <video> 要素を監視する JS を注入
        let script = WKUserScript(
            source: Self.monitorScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        controller.webView = webView

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
    }

    // MARK: - Video monitor script

    /// YouTube ページ内の <video> 要素を探して再生状態をポーリングする JS。
    /// ページ遷移後に video 要素が現れるまでリトライする。
    private static let monitorScript = """
    (function() {
        var interval = null;
        var readySent = false;

        function findVideo() {
            return document.querySelector('video');
        }

        function startMonitor() {
            if (interval) return;

            // メディアイベント観測（広告→本編の切り替わり検知用）
            var video = findVideo();
            if (video) {
                var lastSrc = video.currentSrc || '';
                var mediaEvents = [
                    'loadedmetadata', 'durationchange', 'emptied',
                    'loadstart', 'abort', 'ended', 'play', 'pause'
                ];
                mediaEvents.forEach(function(evName) {
                    video.addEventListener(evName, function() {
                        var newSrc = video.currentSrc || '';
                        var srcChanged = (newSrc !== lastSrc);
                        if (srcChanged) lastSrc = newSrc;
                        try {
                            window.webkit.messageHandlers.ytState.postMessage({
                                event: 'mediaDebug',
                                mediaEvent: evName,
                                duration: video.duration || 0,
                                currentTime: video.currentTime || 0,
                                srcChanged: srcChanged,
                                readyState: video.readyState
                            });
                        } catch(e) {}
                    });
                });
            }

            interval = setInterval(function() {
                var video = findVideo();
                if (!video) return;

                if (!readySent) {
                    readySent = true;
                    try {
                        window.webkit.messageHandlers.ytState.postMessage({
                            event: 'ready',
                            title: document.title || ''
                        });
                    } catch(e) {}
                }

                try {
                    window.webkit.messageHandlers.ytState.postMessage({
                        event: 'timeUpdate',
                        currentTime: video.currentTime || 0,
                        duration: video.duration || 0
                    });

                    window.webkit.messageHandlers.ytState.postMessage({
                        event: 'stateChange',
                        state: video.paused ? 2 : 1
                    });
                } catch(e) {}
            }, 200);
        }

        // video 要素が遅延ロードされる場合があるのでリトライ
        var retryCount = 0;
        var retryInterval = setInterval(function() {
            if (findVideo()) {
                clearInterval(retryInterval);
                startMonitor();
            } else if (++retryCount > 50) {
                clearInterval(retryInterval);
            }
        }, 500);

        // 即座に見つかった場合
        if (findVideo()) {
            clearInterval(retryInterval);
            startMonitor();
        }
    })();
    """
}
