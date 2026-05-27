import AVFoundation
import AppKit
import SwiftUI

/// プレビューエリア: 動画レイヤーの上に Caption オーバーレイを重ねる。
///
/// CC Phase 03 で動画編集オーバーレイ (Annotation / Keystroke / Cursor / MouseTrajectory /
/// ClickRipple / Crop / Background / Zoom transform) と関連の `BackgroundLayerView` /
/// `CropOverlayView` を全削除した。CaptionCraft では「動画 + 字幕プレビュー」だけが
/// 必要なので、最小構成に書き直している。
///
/// YouTube モード: yt-dlp でダウンロードした動画を AVPlayer で表示する。
/// ローカル動画と同じ VideoLayerView + CaptionOverlayView を使う。
struct PreviewAreaView: View {
    @ObservedObject var store:    ProjectStore
    @ObservedObject var playback: PlaybackController
    @ObservedObject var timeline: TimelineViewModel
    @ObservedObject var audioDownloader: YouTubeAudioDownloader
    @Binding var youtubeURLText: String

    private var isYouTubeMode: Bool {
        store.project?.media.isYouTubeMode ?? false
    }

    var body: some View {
        GeometryReader { geo in
            let canvas = fittedCanvas(in: geo.size, aspect: editorState.aspectRatio.cgSize)

            ZStack {
                EditorTheme.canvas

                if playback.hasVideo {
                    ZStack {
                        VideoLayerView(
                            player:          playback.player,
                            borderRadius:    0,
                            shadowIntensity: 0,
                            zoomTransform:   ZoomTransform.identity
                        )

                        CaptionOverlayView(
                            store: store,
                            playback: playback,
                            timeline: timeline
                        )
                    }
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { playback.toggle() }
                } else if isYouTubeMode {
                    youtubeLoadingContent
                        .frame(width: canvas.width, height: canvas.height)
                } else {
                    emptyPlaceholder
                        .frame(width: canvas.width, height: canvas.height)
                        .contentShape(Rectangle())
                        .onTapGesture { AppDelegate.shared?.presentOpenVideoPanel() }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - YouTube loading / input

    @ViewBuilder
    private var youtubeLoadingContent: some View {
        ZStack {
            if audioDownloader.isDownloading {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text(audioDownloader.progress.isEmpty ? "読み込み中…" : audioDownloader.progress)
                        .font(.headline)
                        .foregroundStyle(EditorTheme.textSecondary)
                }
            } else if let error = audioDownloader.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(EditorTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("再試行") {
                        startVideoDownload()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                YouTubeInputView(urlText: $youtubeURLText) { url in
                    startVideoDownload()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EditorTheme.canvas)
        .onAppear {
            if let url = store.project?.media.youtubeURL,
               !url.isEmpty,
               !playback.hasVideo,
               !audioDownloader.isDownloading {
                youtubeURLText = url
                startVideoDownload()
            }
        }
    }

    private func startVideoDownload() {
        guard !audioDownloader.isDownloading else { return }
        let urlString = youtubeURLText
        guard YouTubeURLValidator.extractVideoID(urlString) != nil else {
            audioDownloader.errorMessage = "有効な YouTube URL ではありません"
            return
        }
        // プロジェクトに URL を保存
        var media = store.project?.media ?? MediaPaths(screenVideoPath: "")
        media.youtubeURL = urlString
        store.updateMedia(media)

        Task {
            guard let videoURL = await audioDownloader.downloadVideo(from: urlString) else { return }
            // ダウンロード完了 → PlaybackController にロード
            await playback.load(url: videoURL)
            // screenVideoPath にも設定して STT パイプラインが使えるようにする
            var updatedMedia = store.project?.media ?? MediaPaths(screenVideoPath: "")
            updatedMedia.screenVideoPath = videoURL.path
            store.updateMedia(updatedMedia)
        }
    }

    // MARK: - Empty state

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("クリックして動画を開く")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("⌘O")
                .font(.caption)
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))

            Divider().frame(width: 120).padding(.vertical, 8)

            Button {
                AppDelegate.shared?.openYouTubeURL()
            } label: {
                Label("YouTube URL を開く", systemImage: "play.rectangle")
            }
            .buttonStyle(.bordered)

            Text("⌘⇧Y")
                .font(.caption)
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
    }

    // MARK: - Derived

    private var editorState: EditorState {
        store.project?.editor ?? EditorState()
    }

    private func fittedCanvas(in size: CGSize, aspect: CGSize) -> CGSize {
        let targetAspect = aspect.width / max(1, aspect.height)
        let sizeAspect   = size.width / max(1, size.height)
        if sizeAspect > targetAspect {
            return CGSize(width: size.height * targetAspect, height: size.height)
        } else {
            return CGSize(width: size.width, height: size.width / targetAspect)
        }
    }
}

/// CC Phase 03 で `ZoomEngine` が削除されたため、`VideoLayerView` の zoomTransform
/// 引数に渡せる型が無くなった。最小限のスタブとして identity 変換だけを表す型を
/// 同居させておき、`VideoLayerView` 内の transform 適用ロジックは「常に恒等」で
/// 動かす。CC Phase 04 以降で `VideoLayerView` 自体を簡素化する際に削除予定。
struct ZoomTransform {
    var translateX: Double
    var translateY: Double
    var scale: Double

    static let identity = ZoomTransform(translateX: 0, translateY: 0, scale: 1)
}
