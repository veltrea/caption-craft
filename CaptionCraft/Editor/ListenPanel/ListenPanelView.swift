import SwiftUI

/// 聴き直し専用フローティングパネル。ループ再生中にメインウインドウ上に表示される。
///
/// Step 1: 波形 + スライスジャンプ + 速度スライダー + STT テキスト + メモ
/// Step 3: MTAudioProcessingTap で AVPlayer パイプラインに 2 段階 EQ 挿入
struct ListenPanelView: View {
    static func intent() -> String { """
    役割: 聴き直しループ中に表示するフローティングパネル。
          波形表示・スライスジャンプ・速度スライダー・2 段階 EQ (パライコ+グライコ)・
          STT テキスト・メモ入力を提供。
    成熟度: experimental
    依存: PlaybackController (ループ状態), ListenEQProcessor (パイプライン EQ),
          CaptionRegion (字幕)
    """ }

    @ObservedObject var playback: PlaybackController
    @ObservedObject var store: ProjectStore
    @ObservedObject var eqProcessor: ListenEQProcessor
    let sourceURL: URL?
    let onClose: () -> Void

    @State private var memo: String = ""
    @State private var slicePoints: [SliceDetector.SlicePoint] = []
    @State private var scrollContentHeight: CGFloat = 0
    @FocusState private var panelFocused: Bool
    @FocusState private var memoFocused: Bool

    private var loopStartMs: Int { Int(playback.loopRangeStart * 1000) }
    private var loopEndMs: Int { Int(playback.loopRangeEnd * 1000) }

    private var screenMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) * 0.75
    }

    private var sttText: String {
        guard let regions = store.project?.editor.captionRegions else { return "" }
        let overlapping = regions.filter { $0.startMs < loopEndMs && $0.endMs > loopStartMs }
        return overlapping.map(\.text).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(EditorTheme.divider)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    ListenWaveformView(
                        sourceURL: sourceURL,
                        loopStartMs: loopStartMs,
                        loopEndMs: loopEndMs,
                        progress: playback.loopProgress,
                        onSeekRatio: { ratio in
                            let ms = loopStartMs + Int(ratio * Double(loopEndMs - loopStartMs))
                            Task { await playback.seek(to: Double(ms) / 1000.0) }
                        },
                        slicePoints: $slicePoints
                    )

                    transportControls

                    speedControl

                    GraphicEQView(eqProcessor: eqProcessor)

                    if !sttText.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("音声認識テキスト", systemImage: "text.quote")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(EditorTheme.textTertiary)

                            Text(sttText)
                                .font(.system(size: 12))
                                .foregroundStyle(EditorTheme.textSecondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(EditorTheme.surfaceHi.opacity(0.3))
                                )
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Label("字幕テキスト修正", systemImage: "character.cursor.ibeam")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(EditorTheme.textTertiary)

                        HStack(spacing: 8) {
                            TextField("正しい字幕テキストを入力…", text: $memo)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(8)
                                .focused($memoFocused)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(EditorTheme.surfaceHi.opacity(0.5))
                                )

                            Button("採用") { adoptMemo() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(memo.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding(14)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollContentHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
            }
            .frame(maxHeight: scrollContentHeight > 0
                   ? min(scrollContentHeight, screenMaxHeight)
                   : 500)
            .onPreferenceChange(ScrollContentHeightKey.self) { scrollContentHeight = $0 }
        }
        .frame(width: 620)
        .background(EditorTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .focusable()
        .focused($panelFocused)
        .onAppear {
            panelFocused = true
            activateEQ()
        }
        .onDisappear {
            deactivateEQ()
        }
        .task(id: "\(sourceURL?.path ?? "")_\(loopStartMs)_\(loopEndMs)") {
            await detectSlices()
        }
        .onKeyPress(characters: .init(charactersIn: "0123456789")) { press in
            guard !memoFocused else { return .ignored }
            guard let digit = press.characters.first?.wholeNumberValue else { return .ignored }
            let ms: Int
            if digit == 0 {
                ms = loopStartMs
            } else {
                let idx = digit - 1
                guard idx < slicePoints.count else { return .ignored }
                ms = slicePoints[idx].ms
            }
            Task {
                await playback.seek(to: Double(ms) / 1000.0)
                if !playback.isPlaying { playback.play() }
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard !memoFocused else { return .ignored }
            jumpToSlice(forward: false)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !memoFocused else { return .ignored }
            jumpToSlice(forward: true)
            return .handled
        }
        .onKeyPress(.space) {
            guard !memoFocused else { return .ignored }
            playback.toggle()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "ear")
                .font(.system(size: 13))
                .foregroundStyle(.orange)

            Text("聴き直しパネル")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)

            Spacer()

            Text(String(format: "%@ – %@", formatMs(loopStartMs), formatMs(loopEndMs)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(EditorTheme.textTertiary)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(EditorTheme.textTertiary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.06))
    }

    // MARK: - 再生コントロール

    private var transportControls: some View {
        HStack(spacing: 16) {
            Button {
                Task { await playback.seek(to: playback.loopRangeStart) }
                if !playback.isPlaying { playback.play() }
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(EditorTheme.textSecondary)
            .help("先頭に戻る")

            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
            .help(playback.isPlaying ? "一時停止" : "再生")

            Button {
                playback.pause()
                Task { await playback.seek(to: playback.loopRangeStart) }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(EditorTheme.textSecondary)
            .help("停止")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 速度コントロール

    private var speedControl: some View {
        HStack(spacing: 12) {
            Text("速度")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(EditorTheme.textTertiary)

            Button {
                playback.setLoopSpeed(playback.loopSpeedPercent - 1)
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
                playback.setLoopSpeed(playback.loopSpeedPercent + 1)
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

            if playback.isRendering {
                ProgressView()
                    .controlSize(.mini)
                Text("\(Int(playback.renderProgress * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(EditorTheme.textTertiary)
            }
        }
    }

    // MARK: - EQ 制御

    private func activateEQ() {
        playback.activeEQProcessor = eqProcessor
        if let item = playback.player.currentItem {
            eqProcessor.attach(to: item)
        }
    }

    private func deactivateEQ() {
        if let item = playback.player.currentItem {
            eqProcessor.detach(from: item)
        }
        playback.activeEQProcessor = nil
    }

    // MARK: - スライス

    private func detectSlices() async {
        guard let url = sourceURL, loopEndMs > loopStartMs else { return }
        let regions = store.project?.editor.captionRegions ?? []
        var boundaries: [Int] = []
        for r in regions {
            if r.startMs > loopStartMs && r.startMs < loopEndMs { boundaries.append(r.startMs) }
            if r.endMs > loopStartMs && r.endMs < loopEndMs { boundaries.append(r.endMs) }
        }
        slicePoints = await SliceDetector.detect(
            url: url,
            loopStartMs: loopStartMs,
            loopEndMs: loopEndMs,
            regionBoundaries: boundaries
        )
    }

    private func jumpToSlice(forward: Bool) {
        guard !slicePoints.isEmpty else { return }
        let currentMs = Int(playback.currentTime.seconds * 1000)
        if forward {
            if let next = slicePoints.first(where: { $0.ms > currentMs + 30 }) {
                Task {
                    await playback.seek(to: Double(next.ms) / 1000.0)
                    if !playback.isPlaying { playback.play() }
                }
            }
        } else {
            if let prev = slicePoints.last(where: { $0.ms < currentMs - 30 }) {
                Task {
                    await playback.seek(to: Double(prev.ms) / 1000.0)
                    if !playback.isPlaying { playback.play() }
                }
            }
        }
    }

    // MARK: - Actions

    private func adoptMemo() {
        let trimmed = memo.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard var state = store.project?.editor else { return }

        let overlapping = state.captionRegions.filter {
            $0.startMs < loopEndMs && $0.endMs > loopStartMs
        }
        guard let target = overlapping.first,
              let idx = state.captionRegions.firstIndex(where: { $0.id == target.id }) else { return }

        state.captionRegions[idx].text = trimmed
        state.captionRegions[idx].isManuallyEdited = true
        store.commitState(state)
        memo = ""
    }

    private func formatMs(_ ms: Int) -> String {
        let totalSec = ms / 1000
        let min = totalSec / 60
        let sec = totalSec % 60
        let frac = (ms % 1000) / 10
        return String(format: "%02d:%02d.%02d", min, sec, frac)
    }
}

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
