import AVFoundation
import AppKit
import SwiftUI

/// Editor 下部の黒いトランスポートバー。
/// 左: 「N visible timelines」ドロップダウン
/// 中央: 時刻 (現在/総尺) + 前へ / 再生 / 後へ
struct PlaybackControlsView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var playback: PlaybackController
    @ObservedObject var timeline: TimelineViewModel
    @ObservedObject var audioDownloader: YouTubeAudioDownloader
    @ObservedObject var captionTranscriber: CaptionTranscriber

    private var isYouTubeMode: Bool {
        store.project?.media.isYouTubeMode ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            if playback.isSlowLooping {
                slowLoopBar
            }
            HStack(spacing: 14) {
                timelinesDropdown

                Spacer()

                transportCluster

                if isYouTubeMode {
                    youtubeSTTCluster
                }

                Spacer()

                inlineSpeedControl

            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(EditorTheme.chrome)
            .overlay(alignment: .top) {
                Rectangle().fill(EditorTheme.divider).frame(height: 0.5)
            }
        }
    }

    // MARK: - Left dropdown

    private var timelinesDropdown: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 11))
                .foregroundStyle(EditorTheme.textSecondary)
            Text("1 visible timeline")
                .font(.system(size: 11))
                .foregroundStyle(EditorTheme.textSecondary)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(EditorTheme.textTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(EditorTheme.surfaceHi.opacity(0.4))
        )
    }

    // MARK: - Center transport

    private var transportCluster: some View {
        HStack(spacing: 12) {
            Text(formatHMS(currentSeconds))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorTheme.textSecondary)
                .frame(width: 62, alignment: .trailing)

            transportButton("backward.end.fill", help: "先頭へ") {
                Task { await playback.seek(to: 0) }
            }
            transportButton("backward.fill", help: "前のリージョン") {
                seekToPreviousRegion()
            }
            transportButton(playback.isPlaying ? "pause.fill" : "play.fill",
                            help: playback.isPlaying ? "Pause" : "Play",
                            prominent: true) {
                playback.toggle()
            }
            .e2eTrack(id: "editor.playPauseButton", role: "AXButton", label: "再生/一時停止")

            transportButton("forward.fill", help: "次のリージョン") {
                seekToNextRegion()
            }
            transportButton("forward.end.fill", help: "末尾へ") {
                Task { await playback.seek(to: durationSeconds) }
            }

            Text(formatHMS(durationSeconds))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorTheme.textSecondary)
                .frame(width: 62, alignment: .leading)

            fullscreenButton
        }
    }

    private var fullscreenButton: some View {
        Button(action: { toggleFullScreen() }) {
            Image(systemName: "eye")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(EditorTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(EditorTheme.surfaceHi.opacity(0.35))
                )
        }
        .buttonStyle(.borderless)
        .help("Fullscreen Preview")
        .e2eTrack(id: "editor.transport.fullscreenButton", role: "AXButton", label: "Fullscreen Preview")
    }

    private func toggleFullScreen() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        window.toggleFullScreen(nil)
    }

    // MARK: - Transport button

    @ViewBuilder
    private func transportButton(_ system: String, help: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: prominent ? 14 : 12, weight: .semibold))
                .foregroundStyle(prominent ? .white : EditorTheme.textPrimary)
                .frame(width: prominent ? 32 : 26, height: prominent ? 32 : 26)
                .background(
                    Circle().fill(prominent ? EditorTheme.surfaceHi : Color.clear)
                )
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: - Inline speed control

    private static let speedSteps: [Double] = [0.50, 0.75, 1.0, 1.25, 1.5, 2.0]

    private var currentStepIndex: Int {
        let current = playback.playbackSpeed
        return Self.speedSteps.firstIndex(where: { abs($0 - current) < 0.03 })
            ?? Self.speedSteps.enumerated().min(by: { abs($0.element - current) < abs($1.element - current) })!.offset
    }

    private var inlineSpeedControl: some View {
        HStack(spacing: 6) {
            Button {
                stepSpeed(delta: -1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .disabled(currentStepIndex <= 0)

            Text(speedLabel(playback.playbackSpeed))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(
                    abs(playback.playbackSpeed - 1.0) < 0.01
                        ? EditorTheme.textSecondary
                        : .orange
                )
                .frame(width: 40, alignment: .center)

            HStack(spacing: 3) {
                ForEach(0..<Self.speedSteps.count, id: \.self) { i in
                    Circle()
                        .fill(dotColor(at: i))
                        .frame(
                            width: i == currentStepIndex ? 6 : 4,
                            height: i == currentStepIndex ? 6 : 4
                        )
                        .animation(.easeInOut(duration: 0.15), value: currentStepIndex)
                }
            }

            Button {
                stepSpeed(delta: 1)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .disabled(currentStepIndex >= Self.speedSteps.count - 1)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(EditorTheme.surfaceHi.opacity(0.4))
        )
    }

    private func dotColor(at index: Int) -> Color {
        let isNormal = abs(playback.playbackSpeed - 1.0) < 0.01
        let idx = currentStepIndex
        if index == idx {
            return isNormal ? Color(white: 0.75) : .orange
        }
        return Color.white.opacity(0.15)
    }

    private func speedLabel(_ speed: Double) -> String {
        if speed == 1.0 { return "1.0x" }
        return String(format: "%.2gx", speed)
    }

    private func stepSpeed(delta: Int) {
        let steps = Self.speedSteps
        let idx = currentStepIndex
        let newIdx = max(0, min(steps.count - 1, idx + delta))
        playback.setSpeed(steps[newIdx])
    }

    // MARK: - Slow loop bar

    private var slowLoopBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "ear")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

            Text("聴き直しループ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)

            Divider().frame(height: 16)

            Button {
                playback.setLoopSpeed(playback.loopSpeedPercent - 5)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(playback.loopSpeedPercent <= 50)

            Text("\(playback.loopSpeedPercent)%")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(
                    playback.loopSpeedPercent == 100
                        ? EditorTheme.textPrimary
                        : .orange
                )
                .frame(width: 44, alignment: .center)

            Button {
                playback.setLoopSpeed(playback.loopSpeedPercent + 5)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(playback.loopSpeedPercent >= 100)

            Slider(
                value: Binding(
                    get: { Double(playback.loopSpeedPercent) },
                    set: { playback.setLoopSpeed(Int($0)) }
                ),
                in: 50...100,
                step: 1
            )
            .controlSize(.mini)
            .tint(.orange)
            .frame(maxWidth: 200)

            if playback.isRendering {
                ProgressView()
                    .controlSize(.mini)
                Text("\(Int(playback.renderProgress * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(EditorTheme.textTertiary)
            }

            Spacer()

            Button {
                playback.stopSlowLoop()
            } label: {
                Label("停止", systemImage: "xmark.circle.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.3)).frame(height: 0.5)
        }
    }

    // MARK: - Region navigation

    private var sortedRegions: [CaptionRegion] {
        (store.project?.editor.captionRegions ?? []).sorted { $0.startMs < $1.startMs }
    }

    private func seekToPreviousRegion() {
        let regions = sortedRegions
        guard !regions.isEmpty else { return }
        let ms = Int(currentSeconds * 1000)
        if let prev = regions.last(where: { $0.startMs < ms - 100 }) {
            Task { await playback.seek(to: Double(prev.startMs) / 1000.0) }
        } else {
            Task { await playback.seek(to: Double(regions.first!.startMs) / 1000.0) }
        }
    }

    private func seekToNextRegion() {
        let regions = sortedRegions
        guard !regions.isEmpty else { return }
        let ms = Int(currentSeconds * 1000)
        if let next = regions.first(where: { $0.startMs > ms + 100 }) {
            Task { await playback.seek(to: Double(next.startMs) / 1000.0) }
        } else {
            Task { await playback.seek(to: Double(regions.last!.startMs) / 1000.0) }
        }
    }

    // MARK: - Derived

    private var currentSeconds: Double {
        let s = playback.currentTime.seconds
        return s.isFinite ? max(0, s) : 0
    }

    private var durationSeconds: Double {
        let s = playback.duration.seconds
        return s.isFinite ? max(0, s) : 0
    }

    private func formatHMS(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00.00" }
        let total = max(0, seconds)
        let m = Int(total) / 60
        let s = total - Double(m * 60)
        return String(format: "%02d:%05.2f", m, s)
    }

    // MARK: - YouTube download + STT cluster

    // MARK: - YouTube STT cluster

    private var youtubeSTTCluster: some View {
        HStack(spacing: 8) {
            Divider().frame(height: 20)

            if captionTranscriber.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text("字幕生成中…")
                    .font(.system(size: 11))
                    .foregroundStyle(EditorTheme.textSecondary)
            } else {
                Button {
                    captionTranscriber.retranscribeAll(store: store)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 11))
                        Text("字幕を生成")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!playback.hasVideo)
            }

            if let error = audioDownloader.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}
