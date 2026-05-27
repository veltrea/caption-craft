import AppKit
import AVFoundation
import SwiftUI

/// エディタ下部の字幕リスト。
///
/// CC Phase 03 で動画編集タイムライン (Zoom / Trim / Speed / Annotation / TTS / BGM /
/// Narration / Keystroke / Mouse / 横スクロール / プレイヘッド / ラベル列 / 波形表示)
/// を全削除し、字幕区間を時刻順にリスト表示する最小実装に書き直した。
///
/// CC Phase 04 以降で字幕特化の DAW 風タイムライン (横軸 = 時刻、縦軸 = 1 行で
/// 字幕ブロックを並べる) を再構築する予定。
struct TimelineView: View {
    @ObservedObject var store:              ProjectStore
    @ObservedObject var playback:           PlaybackController
    @ObservedObject var timeline:           TimelineViewModel
    @ObservedObject var waveformService:    WaveformService
    @ObservedObject var correctionService:  CorrectionService
    @ObservedObject var dictionaryStore:    DictionaryStore
    @ObservedObject var translationService: TranslationService
    @ObservedObject var transcriber:        CaptionTranscriber
    var llmEndpoint: URL

    /// 横ズーム倍率。1.0 = fit (動画全体が画面幅に収まる)。
    /// 上限は動画長から動的計算 (1px ≒ 1ms に到達する倍率まで)。
    @State private var zoomLevel: Double = 1.0

    /// 自動でプレイヘッド位置に追従スクロールするか。
    /// 再生中はデフォルトで ON。停止中は維持。
    @State private var followPlayhead: Bool = true

    /// 波形 ScrollView の visible 幅 (px)。動的ズーム上限の計算に使う。
    /// GeometryReader から onAppear / onChange で更新する。
    @State private var waveformContainerWidth: CGFloat = 800

    /// 自前スクロール用の offset (px)。0 = 動画先頭、増えるほど後方へ。
    @State private var scrollOffset: CGFloat = 0

    /// 初回ロード時のデフォルトズーム自動設定をしたかどうか。
    /// ユーザーが明示的に変更した後はここを true にして以降の自動調整を抑止。
    @State private var hasInitializedZoom: Bool = false

    // MARK: - リージョン端ドラッグ

    private struct DragEdge {
        let regionID: UUID
        enum Side { case start, end }
        let side: Side
    }

    /// ドラッグ中のリージョン端情報。nil = ドラッグ中でない。
    @State private var dragEdge: DragEdge? = nil

    // MARK: - Option+ドラッグでリージョン新規追加

    /// Option+ドラッグ中の起点 ms。nil = Option+ドラッグ中でない。
    @State private var optionDragAnchorMs: Int? = nil
    /// Option+ドラッグ中の現在位置 ms。
    @State private var optionDragCurrentMs: Int? = nil

    // MARK: - カラム表示モード

    /// 字幕リストの中央・右カラムに何を表示するか。
    enum ColumnMode: String, CaseIterable, Identifiable {
        case translation
        case preCorrection
        case postCorrection

        var id: String { rawValue }

        /// UI 表示用のローカライズ済みラベル
        var label: String {
            switch self {
            case .translation:    return L10n.Timeline.translation
            case .preCorrection:  return L10n.Timeline.preCorrection
            case .postCorrection: return L10n.Timeline.postCorrection
            }
        }
    }

    @State private var middleColumnMode: ColumnMode = .preCorrection
    @State private var rightColumnMode: ColumnMode = .postCorrection

    // MARK: - 字幕テキスト編集

    private enum EditingTarget { case original, translated }
    @State private var editingRegionID: UUID? = nil
    @State private var editingTarget: EditingTarget = .original
    @State private var editingText: String = ""
    @FocusState private var captionTextFocused: Bool

    private static let zoomMin: Double = 0.25
    private static let zoomStep: Double = 1.5

    /// 起動時のデフォルト表示で「画面幅 = 約 N 秒」になる秒数。
    /// 字幕単位の編集を意識して 10 秒程度に設定。
    private static let defaultVisibleSeconds: Double = 10.0

    /// 動的ズーム上限。動画長 / コンテナ幅 = 1px あたり ms 数を決定する倍率。
    /// 例えば 1 時間動画 (3,600,000ms) で コンテナ幅 800px なら、最大倍率は 4500。
    /// この倍率で 1px = 1ms になり、それ以上拡大しても情報量が増えない。
    /// データがロードされていない初期状態は fallback で 50 倍にしておく。
    private var dynamicZoomMax: Double {
        let durationMs = waveformService.waveform?.durationMs ?? fallbackDurationMs
        guard durationMs > 0, waveformContainerWidth > 0 else {
            return 50.0
        }
        let maxNeeded = Double(durationMs) / Double(waveformContainerWidth)
        return max(50.0, maxNeeded)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            minimap
                .frame(height: 36)
            Divider()
            zoomableWaveform
                .frame(height: 100)
            Divider()
            captionListHeader
            captionList
        }
    }

    // MARK: - Body sub-views (分割理由: SwiftUI の型推論タイムアウト回避)

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("字幕")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(EditorTheme.textPrimary)

            // 現在の視野範囲 (横スクロール + ズーム時の位置感覚を補助)
            if let range = visibleRangeLabel {
                Text(range)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if waveformService.isExtracting {
                ProgressView()
                    .controlSize(.mini)
                Text("波形抽出中…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if let error = waveformService.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 10))
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Spacer()

            zoomControls

            // 追従トグル
            Toggle(isOn: $followPlayhead) {
                Image(systemName: followPlayhead ? "location.fill" : "location")
                    .font(.system(size: 10))
            }
            .toggleStyle(.button)
            .controlSize(.mini)
            .help(L10n.Timeline.followPlayhead)

            Button {
                let ms = currentMs
                if let id = timeline.addCaption(atMs: ms, store: store) {
                    enterEditMode(regionID: id)
                }
            } label: {
                Label("追加", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(EditorTheme.chrome)
    }

    @ViewBuilder
    private var captionListHeader: some View {
        // 字幕リストヘッダー（3カラム: 原文 + 中央モード選択 + 右モード選択）
        HStack(spacing: 8) {
            Spacer()
                .frame(width: 80 + 24 + 8)
            Text("原文")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 1)
            columnPicker(selection: $middleColumnMode)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 1)
            columnPicker(selection: $rightColumnMode)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(EditorTheme.chrome.opacity(0.5))
    }

    @ViewBuilder
    private var captionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let listRegions = listCaptionRegions
                    ForEach(listRegions, id: \.id) { region in
                        captionListRow(region)
                        Divider().opacity(0.1)
                    }

                    if listRegions.isEmpty {
                        emptyState
                    }
                }
            }
            .onChange(of: store.scrollToRegionID) { targetID in
                guard let targetID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
                // 波形トラックも該当 region の開始位置に合わせて横スクロール
                if let target = captionRegions.first(where: { $0.id == targetID }) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scrollWaveformTo(ms: Double(target.startMs))
                    }
                }
                // リセットして次の scrollTo トリガーを受け付ける
                store.scrollToRegionID = nil
            }
            // 波形リージョン選択時に字幕リストを追従スクロール
            .onChange(of: timeline.selectedItemID) { selectedID in
                guard let selectedID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
        .background(EditorTheme.canvas)
    }

    @ViewBuilder
    private func captionListRow(_ region: CaptionRegion) -> some View {
        let rowBackground: Color = (timeline.selectedItemID == region.id)
            ? Color.white.opacity(0.06)
            : Color.clear

        captionRow(region)
            .id(region.id)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                editingText = region.text
                editingTarget = .original
                editingRegionID = region.id
            }
            .onTapGesture(count: 1) {
                timeline.select(itemID: region.id)
                Task { await playback.seek(to: Double(region.startMs) / 1000.0) }
                // 字幕クリック時に波形を該当リージョン位置までスクロールする。
                // 再生中じゃないと自動追従が効かないので明示的に呼ぶ。
                scrollWaveformTo(ms: Double(region.startMs))
            }
    }

    private var currentMs: Int {
        let s = playback.currentTime.seconds
        return s.isFinite ? max(0, Int(s * 1000)) : 0
    }

    // MARK: - Zoomable waveform

    private var zoomableWaveform: some View {
        GeometryReader { outerGeo in
            let waveW = waveformWidth(in: outerGeo.size)
            let maxOffset = max(0, waveW - outerGeo.size.width)

            ZStack(alignment: .topLeading) {
                // 1. 波形本体: 全幅で描画して offset 分だけ左にずらす。
                //    interaction (click / scroll) は ScrollEventReceiver overlay 側に
                //    一任するため、WaveformView は描画専用 (allowsHitTesting=false)。
                WaveformView(
                    waveform: waveformService.waveform,
                    captionRegions: captionRegions,
                    currentMs: currentMs,
                    selectedRegionID: timeline.selectedItemID,
                    fallbackDurationMs: fallbackDurationMs,
                    onSeek: { _ in },
                    onSelectRegion: { _ in }
                )
                // ※ .id() は付けない。
                // 付けると Whisper がリージョンを追加するたびに WaveformView 全体が
                // 再生成され、波形 Canvas (数千ピーク) が毎回再描画されて致命的に遅くなる。
                // SwiftUI の自然な diff (CaptionRegion: Equatable) に任せる。
                .frame(width: waveW, height: outerGeo.size.height)
                .offset(x: -scrollOffset, y: 0)
                .allowsHitTesting(false)
            }
            .clipped()
            // Option+ドラッグ中のプレビュー矩形
            .overlay(
                optionDragPreview(waveW: waveW, containerWidth: outerGeo.size.width)
                    .allowsHitTesting(false)
            )
            // 前面に scrollWheel + mouseDown 受信用の NSView を被せる。
            // .background だと WaveformView (Canvas) が前面に来てしまい、
            // SwiftUI の縦 ScrollView (字幕一覧) に scrollWheel が流れる。
            // .overlay で前面に出すと NSView が確実に scrollWheel を受ける。
            .overlay(
                ScrollEventReceiver(
                    onScroll: { dx in
                        let new = scrollOffset + dx
                        scrollOffset = max(0, min(maxOffset, new))
                    },
                    onClick: { point in
                        // リージョン端に近ければドラッグ開始
                        if let edge = detectEdge(at: point, waveW: waveW) {
                            dragEdge = edge
                            timeline.select(itemID: edge.regionID)
                            return
                        }

                        // 通常クリック: シーク / 選択
                        let absoluteX = point.x + scrollOffset
                        guard let durationMs = waveformService.waveform?.durationMs,
                              durationMs > 0, waveW > 0 else { return }
                        let ratio = max(0, min(1, absoluteX / waveW))
                        let ms = Int(ratio * Double(durationMs))

                        if let hit = captionRegions.first(where: {
                            ms >= $0.startMs && ms <= $0.endMs
                        }) {
                            timeline.select(itemID: hit.id)
                            Task { await playback.seek(to: Double(hit.startMs) / 1000.0) }
                        } else {
                            Task { await playback.seek(to: Double(ms) / 1000.0) }
                        }
                    },
                    onDrag: { point in
                        guard let edge = dragEdge else { return }
                        guard let durationMs = waveformService.waveform?.durationMs,
                              durationMs > 0, waveW > 0 else { return }
                        let absoluteX = point.x + scrollOffset
                        let ratio = max(0, min(1, absoluteX / waveW))
                        let ms = max(0, min(durationMs, Int(ratio * Double(durationMs))))

                        guard var region = captionRegions.first(where: { $0.id == edge.regionID }) else { return }
                        switch edge.side {
                        case .start:
                            region.startMs = min(ms, region.endMs - 100)
                        case .end:
                            region.endMs = max(ms, region.startMs + 100)
                        }
                        region.isManuallyEdited = true
                        timeline.updateCaption(region, store: store)
                    },
                    onDragEnd: {
                        guard let edge = dragEdge else { return }
                        dragEdge = nil
                        if let region = captionRegions.first(where: { $0.id == edge.regionID }) {
                            timeline.commitCaption(region, store: store)
                        }
                    },
                    onHover: { point in
                        if dragEdge != nil || detectEdge(at: point, waveW: waveW) != nil {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    },
                    onRightClick: { point in
                        let absoluteX = point.x + scrollOffset
                        guard let durationMs = waveformService.waveform?.durationMs,
                              durationMs > 0, waveW > 0 else { return }
                        let ratio = max(0, min(1, absoluteX / waveW))
                        let ms = Int(ratio * Double(durationMs))
                        showWaveformContextMenu(atMs: ms)
                    },
                    onOptionDragStart: { point in
                        let absoluteX = point.x + scrollOffset
                        guard let durationMs = waveformService.waveform?.durationMs,
                              durationMs > 0, waveW > 0 else { return }
                        let ratio = max(0, min(1, absoluteX / waveW))
                        let ms = Int(ratio * Double(durationMs))
                        optionDragAnchorMs = ms
                        optionDragCurrentMs = ms
                    },
                    onOptionDragMove: { point in
                        let absoluteX = point.x + scrollOffset
                        guard let durationMs = waveformService.waveform?.durationMs,
                              durationMs > 0, waveW > 0 else { return }
                        let ratio = max(0, min(1, absoluteX / waveW))
                        let ms = max(0, min(durationMs, Int(ratio * Double(durationMs))))
                        optionDragCurrentMs = ms
                    },
                    onOptionDragEnd: {
                        guard let anchor = optionDragAnchorMs,
                              let current = optionDragCurrentMs else {
                            optionDragAnchorMs = nil
                            optionDragCurrentMs = nil
                            return
                        }
                        let startMs = min(anchor, current)
                        let endMs = max(anchor, current)
                        optionDragAnchorMs = nil
                        optionDragCurrentMs = nil

                        // 最低 100ms 未満のドラッグは誤操作として無視
                        guard endMs - startMs >= 100 else { return }
                        addRegionByOptionDrag(startMs: startMs, endMs: endMs)
                    }
                )
            )
            .onAppear {
                waveformContainerWidth = outerGeo.size.width
                applyDefaultZoomIfNeeded()
            }
            .onChange(of: outerGeo.size.width) { newWidth in
                waveformContainerWidth = newWidth
                applyDefaultZoomIfNeeded()
            }
            .onChange(of: waveformService.waveform?.durationMs ?? 0) { _ in
                applyDefaultZoomIfNeeded()
            }
            .onChange(of: currentMs) { _ in
                // 再生中 + 追従 ON: プレイヘッドを画面中央に保つよう offset 更新。
                guard playback.isPlaying, followPlayhead else { return }
                let target = playheadX(in: outerGeo.size) - outerGeo.size.width / 2
                let clamped = max(0, min(maxOffset, target))
                scrollOffset = clamped
            }
            .onChange(of: zoomLevel) { _ in
                // ズーム変更時はプレイヘッドを画面中央に維持する (拡大の中心が
                // ジャンプしないようにする UX)。
                let target = playheadX(in: outerGeo.size) - outerGeo.size.width / 2
                scrollOffset = max(0, min(maxOffset, target))
            }
        }
    }

    // MARK: - Minimap

    /// 動画全体を常に画面幅に収めて表示し、メイン波形の現在表示範囲を
    /// 矩形 (viewport) でハイライトするミニマップ。
    ///
    /// DAW / 動画編集ソフト (Premiere / DaVinci 等) のタイムライン下端に
    /// あるのと同じ役割。
    /// - 全体像が常に見える (どこに字幕が密集しているかなどが俯瞰できる)
    /// - 現在の表示範囲 = メイン波形の可視窓
    /// - クリック / ドラッグで一瞬で別の場所にジャンプ
    private var minimap: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 背景
                Rectangle()
                    .fill(Color.black.opacity(0.45))

                // 1. エンベロープ (filled) として波形を描画。
                //    縦線スタイルでは小さなミニマップで「縞模様」になって見えないため、
                //    peak の上下を path で結んで fill する DAW 風の表示にする。
                Canvas { context, size in
                    drawMinimapEnvelope(context: &context, size: size)
                    drawMinimapPlayhead(context: &context, size: size)
                }
                .allowsHitTesting(false)

                // 2. 現在の viewport (メイン波形の可視範囲) を矩形で示す。
                viewportIndicator(minimapWidth: geo.size.width, minimapHeight: geo.size.height)
                    .allowsHitTesting(false)
            }
            // ミニマップでのクリック / ドラッグ → メイン波形の scroll をジャンプ
            .overlay(
                ScrollEventReceiver(
                    onScroll: { _ in
                        // ミニマップ上でのスクロール操作は意味がないので無視
                    },
                    onClick: { point in
                        jumpFromMinimap(clickX: point.x, minimapWidth: geo.size.width)
                    }
                )
            )
        }
    }

    /// ミニマップ用の「エンベロープ」描画。
    /// 各列の peak を上下対称の振幅として、上エッジを左→右、下エッジを右→左に
    /// 結んで閉じた Path を作り、fill する。
    /// 縦線描画と違って小さい高さでも輪郭として認識できる。
    private func drawMinimapEnvelope(context: inout GraphicsContext, size: CGSize) {
        guard let waveform = waveformService.waveform,
              !waveform.peaks.isEmpty else { return }

        let peaks = waveform.peaks
        let midY = size.height / 2
        let columns = max(1, Int(size.width))
        let peakCount = peaks.count

        var topPoints: [CGPoint] = []
        var bottomPoints: [CGPoint] = []
        topPoints.reserveCapacity(columns)
        bottomPoints.reserveCapacity(columns)

        for col in 0..<columns {
            // 比率ベース indexing。columns ≷ peaks のいずれでも全長をカバーする。
            let startIdx = (col * peakCount) / columns
            let nextIdx  = ((col + 1) * peakCount) / columns
            let endIdx   = max(startIdx + 1, nextIdx)
            let safeEnd  = min(endIdx, peakCount)
            guard startIdx < safeEnd else { continue }
            var localPeak: Float = 0
            for i in startIdx..<safeEnd {
                if peaks[i] > localPeak { localPeak = peaks[i] }
            }
            // 振幅は midY を中心に上下対称。0.42 で上下合計 84% を占有。
            let amp = CGFloat(localPeak) * (size.height * 0.42)
            let x = CGFloat(col) + 0.5
            topPoints.append(CGPoint(x: x, y: midY - amp))
            bottomPoints.append(CGPoint(x: x, y: midY + amp))
        }

        guard let first = topPoints.first else { return }

        var path = Path()
        path.move(to: first)
        for p in topPoints.dropFirst() { path.addLine(to: p) }
        for p in bottomPoints.reversed() { path.addLine(to: p) }
        path.closeSubpath()

        context.fill(path, with: .color(.cyan.opacity(0.55)))
    }

    /// ミニマップ上のプレイヘッド (細い縦線)。
    private func drawMinimapPlayhead(context: inout GraphicsContext, size: CGSize) {
        guard let durationMs = waveformService.waveform?.durationMs,
              durationMs > 0 else { return }
        let ratio = Double(currentMs) / Double(durationMs)
        let x = CGFloat(ratio) * size.width
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(.red.opacity(0.85)), lineWidth: 1)
    }

    /// ミニマップ内で「現在表示範囲」を示すハイライト矩形。
    @ViewBuilder
    private func viewportIndicator(minimapWidth: CGFloat, minimapHeight: CGFloat) -> some View {
        if let durationMs = waveformService.waveform?.durationMs,
           durationMs > 0,
           waveformContainerWidth > 0 {
            let mainWaveW = max(1, Double(waveformContainerWidth) * zoomLevel)
            let viewportXRatio = Double(scrollOffset) / mainWaveW
            let viewportWRatio = Double(waveformContainerWidth) / mainWaveW
            let viewportX = CGFloat(viewportXRatio) * minimapWidth
            let viewportW = max(6, CGFloat(viewportWRatio) * minimapWidth)

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: viewportW, height: minimapHeight)
                .overlay(
                    Rectangle()
                        .stroke(Color.white.opacity(0.75), lineWidth: 1)
                )
                .offset(x: viewportX)
        }
    }

    /// ミニマップ上のクリック x 座標から、対応する動画 ms を計算し、
    /// その ms が **メイン波形の中央** に来るよう scrollOffset を更新する。
    private func jumpFromMinimap(clickX: CGFloat, minimapWidth: CGFloat) {
        guard let durationMs = waveformService.waveform?.durationMs,
              durationMs > 0,
              waveformContainerWidth > 0,
              minimapWidth > 0 else { return }

        let ratio = max(0, min(1, Double(clickX) / Double(minimapWidth)))
        let targetMs = ratio * Double(durationMs)
        scrollWaveformTo(ms: targetMs)
    }

    /// 指定した ms 位置がメイン波形の中央に来るよう scrollOffset を更新する。
    /// 字幕クリック・ミニマップクリックなど、任意のシークから呼ばれる。
    private func scrollWaveformTo(ms: Double) {
        guard let durationMs = waveformService.waveform?.durationMs,
              durationMs > 0,
              waveformContainerWidth > 0 else { return }

        let mainWaveW = Double(waveformContainerWidth) * zoomLevel
        let pxPerMs = mainWaveW / Double(durationMs)
        let target = CGFloat(ms * pxPerMs) - waveformContainerWidth / 2
        let maxOffset = max(0, mainWaveW - Double(waveformContainerWidth))
        scrollOffset = max(0, min(CGFloat(maxOffset), target))
    }

    /// ヘッダーに出す「現在の視野範囲」(例: 0:23.5 → 0:33.5)。
    /// 横スクロール + ズーム時の自分の位置感覚を補助する。
    private var visibleRangeLabel: String? {
        guard let durationMs = waveformService.waveform?.durationMs,
              durationMs > 0,
              waveformContainerWidth > 0 else { return nil }
        let waveW = Double(waveformContainerWidth) * zoomLevel
        guard waveW > 0 else { return nil }
        let pxPerMs = waveW / Double(durationMs)
        guard pxPerMs > 0 else { return nil }

        let startMs = Int(Double(scrollOffset) / pxPerMs)
        let endMs = Int(Double(scrollOffset + waveformContainerWidth) / pxPerMs)
        return "\(formatMs(max(0, startMs))) – \(formatMs(min(durationMs, endMs)))"
    }

    /// ズームコントロールから呼ばれる setter。動的上限を超える倍率を要求された場合は
    /// 上限でクランプする。明示変更があったので以降の自動調整は抑止。
    private func setZoom(_ raw: Double) {
        let clamped = max(Self.zoomMin, min(dynamicZoomMax, raw))
        zoomLevel = clamped
        hasInitializedZoom = true
    }

    /// 初回ロード時に「画面幅 ≈ defaultVisibleSeconds」になる倍率を適用する。
    /// hasInitializedZoom が false かつ波形がロード済み + コンテナ幅が確定して
    /// いるときだけ実行する。
    private func applyDefaultZoomIfNeeded() {
        guard !hasInitializedZoom,
              let durationMs = waveformService.waveform?.durationMs,
              durationMs > 0,
              waveformContainerWidth > 0 else { return }

        // 必要倍率 = 全動画長 / デフォルト表示秒数
        // 例: 30 分動画で defaultVisibleSeconds=10 なら zoom=180 倍
        let durationSec = Double(durationMs) / 1000.0
        let needed = durationSec / Self.defaultVisibleSeconds

        // 短い動画 (< defaultVisibleSeconds * 1.2) は fit のままで良い
        guard needed > 1.2 else {
            hasInitializedZoom = true
            return
        }

        let clamped = max(Self.zoomMin, min(dynamicZoomMax, needed))
        zoomLevel = clamped
        hasInitializedZoom = true
        AppLog.playback.info("デフォルトズーム適用: zoom=\(String(format: "%.1f", clamped))x (durationSec=\(String(format: "%.1f", durationSec)), targetVisibleSec=\(Self.defaultVisibleSeconds))")
    }

    /// ズーム後の波形コンテンツ幅。outer の width を基準に zoomLevel 倍する。
    private func waveformWidth(in outerSize: CGSize) -> CGFloat {
        let base = max(100, outerSize.width)
        return base * CGFloat(zoomLevel)
    }

    /// スクロール座標系内のプレイヘッド X 位置。
    private func playheadX(in outerSize: CGSize) -> CGFloat {
        guard let durationMs = waveformService.waveform?.durationMs, durationMs > 0 else {
            return 0
        }
        let ratio = Double(currentMs) / Double(durationMs)
        return waveformWidth(in: outerSize) * CGFloat(ratio)
    }

    // MARK: - Zoom controls

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                setZoom(zoomLevel / Self.zoomStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(zoomLevel <= Self.zoomMin)
            .keyboardShortcut("-", modifiers: [.command])
            .help(L10n.Timeline.zoomOut)

            Button {
                setZoom(1.0)
            } label: {
                Text(zoomLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(minWidth: 60)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .keyboardShortcut("0", modifiers: [.command])
            .help(L10n.Timeline.fitToView)

            Button {
                setZoom(zoomLevel * Self.zoomStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(zoomLevel >= dynamicZoomMax)
            .keyboardShortcut("=", modifiers: [.command])
            .help(L10n.Timeline.zoomIn)
        }
    }

    /// 現在の解像度を「100%」「2.0x」「1ms/px」などで表示する。
    /// 拡大されると倍率表示、十分拡大されると ms/px 表示に切り替えて
    /// 物理単位として読みやすくする。
    private var zoomLabel: String {
        guard let durationMs = waveformService.waveform?.durationMs,
              durationMs > 0,
              waveformContainerWidth > 0 else {
            return String(format: "%.0f%%", zoomLevel * 100)
        }
        let totalPx = Double(waveformContainerWidth) * zoomLevel
        let msPerPx = Double(durationMs) / totalPx
        if msPerPx <= 10 {
            return String(format: "%.1f ms/px", msPerPx)
        }
        if zoomLevel < 10 {
            return String(format: "%.0f%%", zoomLevel * 100)
        }
        return String(format: "%.1fx", zoomLevel)
    }

    // MARK: - Option+ドラッグ プレビュー & 確定

    /// Option+ドラッグ中に半透明の矩形でリージョン作成範囲をプレビューする。
    @ViewBuilder
    private func optionDragPreview(waveW: CGFloat, containerWidth: CGFloat) -> some View {
        if let anchor = optionDragAnchorMs,
           let current = optionDragCurrentMs,
           let durationMs = waveformService.waveform?.durationMs,
           durationMs > 0, waveW > 0 {
            let pxPerMs = waveW / CGFloat(durationMs)
            let startMs = min(anchor, current)
            let endMs = max(anchor, current)
            let x = CGFloat(startMs) * pxPerMs - scrollOffset
            let w = max(1, CGFloat(endMs - startMs) * pxPerMs)

            Rectangle()
                .fill(Color.green.opacity(0.2))
                .overlay(
                    Rectangle()
                        .stroke(Color.green.opacity(0.8), lineWidth: 1.5)
                )
                .frame(width: w)
                .offset(x: x)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// Option+ドラッグ確定時にリージョンを作成する。
    private func addRegionByOptionDrag(startMs: Int, endMs: Int) {
        guard var state = store.project?.editor else { return }
        var region = CaptionRegion(startMs: startMs, endMs: endMs)
        region.isManuallyEdited = true
        region.sourceLanguage = state.captionSettings.language
        state.captionRegions.append(region)
        store.commitState(state)
        timeline.select(itemID: region.id)
        enterEditMode(regionID: region.id)
    }

    /// リージョン作成直後にテキスト編集モードに入る共通処理。
    private func enterEditMode(regionID: UUID) {
        store.scrollToRegionID = regionID
        editingText = ""
        editingTarget = .original
        editingRegionID = regionID
    }

    // MARK: - Waveform context menu

    private func showWaveformContextMenu(atMs ms: Int) {
        let menu = NSMenu()

        // リージョンにヒットしたかどうかで分岐
        if let hit = captionRegions.first(where: { ms >= $0.startMs && ms <= $0.endMs }) {
            buildCaptionNSMenu(menu, for: hit)
        } else {
            let item = NSMenuItem(
                title: "ここに字幕を追加 (\(formatMs(ms)))",
                action: #selector(WaveformMenuTarget.addCaptionAction(_:)),
                keyEquivalent: ""
            )
            let target = WaveformMenuTarget {
                if let id = timeline.addCaption(atMs: ms, store: store) {
                    enterEditMode(regionID: id)
                }
            }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// captionContextMenu (SwiftUI) と同じ内容を NSMenu として構築する。
    /// 波形上のリージョン右クリック用。
    private func buildCaptionNSMenu(_ menu: NSMenu, for region: CaptionRegion) {
        let regions = captionRegions
        guard let idx = regions.firstIndex(where: { $0.id == region.id }) else { return }

        // --- 結合 ---
        if idx > 0 {
            addMenuItem(to: menu, title: "前の字幕と結合") { [self] in
                mergeRegion(at: idx, withPrevious: true)
            }
        }
        if idx < regions.count - 1 {
            addMenuItem(to: menu, title: "次の字幕と結合") { [self] in
                mergeRegion(at: idx, withPrevious: false)
            }
        }

        // --- 分割 ---
        if canSplitRegion(region.text) {
            addMenuItem(to: menu, title: "字幕を分割") { [self] in
                splitRegion(at: idx)
            }
        }

        // --- 句読点分割結合 ---
        let hasSentence = textHasSentenceBreak(region.text)
        let hasComma = textHasBreak(region.text, using: Self.commaBreakers)
        if hasSentence || hasComma {
            menu.addItem(.separator())
            if hasSentence {
                if idx > 0 {
                    addMenuItem(to: menu, title: "句点まで前と結合") { [self] in
                        mergeUpToSentenceEnd(at: idx)
                    }
                }
                if idx < regions.count - 1 {
                    addMenuItem(to: menu, title: "句点以降を次と結合") { [self] in
                        mergeAfterSentenceEnd(at: idx)
                    }
                }
            }
            if hasComma {
                if idx > 0 {
                    addMenuItem(to: menu, title: "読点まで前と結合") { [self] in
                        mergeUpToBreak(at: idx, using: Self.commaBreakers)
                    }
                }
                if idx < regions.count - 1 {
                    addMenuItem(to: menu, title: "読点以降を次と結合") { [self] in
                        mergeAfterBreak(at: idx, using: Self.commaBreakers)
                    }
                }
            }
        }

        // --- LLM 校正 / 翻訳 ---
        menu.addItem(.separator())
        let correctItem = addMenuItem(to: menu, title: L10n.Timeline.llmCorrection) { [self] in
            correctSingleRegion(at: idx)
        }
        correctItem.isEnabled = !correctionService.isRunning

        let translateItem = addMenuItem(to: menu, title: L10n.Timeline.translate) { [self] in
            translateSingleRegion(region)
        }
        translateItem.isEnabled = !translationService.isTranslating

        // --- ループ再生 ---
        menu.addItem(.separator())
        if playback.isSlowLooping {
            addMenuItem(to: menu, title: "ループ停止") { [self] in
                playback.stopSlowLoop()
            }
        } else {
            addMenuItem(to: menu, title: "ループ再生") { [self] in
                let startSec = Double(region.startMs) / 1000.0
                let endSec = Double(region.endMs) / 1000.0
                playback.startSlowLoop(regionStartSec: startSec, regionEndSec: endSec)
            }
        }

        // --- クロスチェック ---
        let primary = PreferencesStore.shared.sttEngine
        let hasCandidates = STTEngineType.allCases.contains { type in
            type != primary && (type == .parakeet || type == .qwen3)
        }
        if hasCandidates {
            menu.addItem(.separator())
            let inFlight = transcriber.ensembleInFlight.contains(region.id)
            let title = inFlight ? "別音声認識エンジンで解析中…" : "別音声認識エンジンで解析"
            let item = addMenuItem(to: menu, title: title) { [self] in
                transcriber.startCrossCheck(regionID: region.id, store: store)
            }
            item.isEnabled = !inFlight
        }

        // --- 別の言語で再書き起こし ---
        let retranscribeMenu = NSMenu()
        let retranscribeLanguages: [(code: String, name: String)] = [
            ("fr", "フランス語"),
            ("en", "英語"),
            ("ja", "日本語"),
            ("de", "ドイツ語"),
            ("es", "スペイン語"),
            ("it", "イタリア語"),
            ("pt", "ポルトガル語"),
            ("ko", "韓国語"),
            ("zh", "中国語"),
            ("ru", "ロシア語"),
        ]
        for lang in retranscribeLanguages {
            addMenuItem(to: retranscribeMenu, title: lang.name) { [self] in
                transcriber.retranscribeWithLanguage(
                    regionID: region.id,
                    language: lang.code,
                    store: store
                )
            }
        }
        let retranscribeItem = NSMenuItem(title: "別の言語で再書き起こし", action: nil, keyEquivalent: "")
        retranscribeItem.submenu = retranscribeMenu
        menu.addItem(.separator())
        menu.addItem(retranscribeItem)

        // --- 削除 ---
        menu.addItem(.separator())
        addMenuItem(to: menu, title: "削除") { [self] in
            deleteRegion(id: region.id)
        }
    }

    @discardableResult
    private func addMenuItem(to menu: NSMenu, title: String, action: @escaping () -> Void) -> NSMenuItem {
        let target = WaveformMenuTarget(action)
        let item = NSMenuItem(
            title: title,
            action: #selector(WaveformMenuTarget.menuAction(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target
        menu.addItem(item)
        return item
    }

    // MARK: - Edge detection (リージョン端ドラッグ用)

    /// クリック/ホバー位置がリージョンの左右端に近いか判定。
    /// threshold (px) 以内ならドラッグ対象として返す。
    private func detectEdge(at viewPoint: CGPoint, waveW: CGFloat) -> DragEdge? {
        guard let durationMs = waveformService.waveform?.durationMs,
              durationMs > 0, waveW > 0 else { return nil }
        let pxPerMs = waveW / Double(durationMs)
        let threshold: CGFloat = 6
        let absoluteX = viewPoint.x + scrollOffset

        for region in captionRegions {
            let endX = CGFloat(Double(region.endMs) * pxPerMs)
            if abs(absoluteX - endX) <= threshold {
                return DragEdge(regionID: region.id, side: .end)
            }
            let startX = CGFloat(Double(region.startMs) * pxPerMs)
            if abs(absoluteX - startX) <= threshold {
                return DragEdge(regionID: region.id, side: .start)
            }
        }
        return nil
    }

    // MARK: - 字幕テキスト編集

    private func commitCaptionEdit() {
        guard let id = editingRegionID else { return }
        let target = editingTarget
        editingRegionID = nil
        guard var region = captionRegions.first(where: { $0.id == id }) else { return }

        switch target {
        case .original:
            guard editingText != region.text else { return }
            region.text = editingText
            region.isManuallyEdited = true
            region.confidence = 1.0
        case .translated:
            guard editingText != (region.translatedText ?? "") else { return }
            region.translatedText = editingText.isEmpty ? nil : editingText
        }
        timeline.commitCaption(region, store: store)
    }

    // MARK: - 字幕コンテキストメニュー

    @ViewBuilder
    private func captionContextMenu(for region: CaptionRegion) -> some View {
        let regions = captionRegions
        let idx = regions.firstIndex(where: { $0.id == region.id })

        if let idx, idx > 0 {
            Button("前の字幕と結合") {
                mergeRegion(at: idx, withPrevious: true)
            }
        }
        if let idx, idx < regions.count - 1 {
            Button("次の字幕と結合") {
                mergeRegion(at: idx, withPrevious: false)
            }
        }

        if let idx, canSplitRegion(region.text) {
            Button("字幕を分割") {
                splitRegion(at: idx)
            }
        }

        let hasPartialBreak = textHasSentenceBreak(region.text)
            || textHasBreak(region.text, using: Self.commaBreakers)
        if let idx, hasPartialBreak {
            Divider()
            if textHasSentenceBreak(region.text) {
                if idx > 0 {
                    Button("句点まで前と結合") {
                        mergeUpToSentenceEnd(at: idx)
                    }
                }
                if idx < regions.count - 1 {
                    Button("句点以降を次と結合") {
                        mergeAfterSentenceEnd(at: idx)
                    }
                }
            }
            if textHasBreak(region.text, using: Self.commaBreakers) {
                if idx > 0 {
                    Button("読点まで前と結合") {
                        mergeUpToBreak(at: idx, using: Self.commaBreakers)
                    }
                }
                if idx < regions.count - 1 {
                    Button("読点以降を次と結合") {
                        mergeAfterBreak(at: idx, using: Self.commaBreakers)
                    }
                }
            }
        }

        Divider()

        Button(L10n.Timeline.llmCorrection) {
            if let idx {
                correctSingleRegion(at: idx)
            }
        }
        .disabled(correctionService.isRunning)

        Button(L10n.Timeline.translate) {
            translateSingleRegion(region)
        }
        .disabled(translationService.isTranslating)

        Divider()

        if playback.isSlowLooping {
            Button("ループ停止") {
                playback.stopSlowLoop()
            }
        } else {
            Button("ループ再生") {
                let startSec = Double(region.startMs) / 1000.0
                let endSec = Double(region.endMs) / 1000.0
                playback.startSlowLoop(regionStartSec: startSec, regionEndSec: endSec)
            }
        }

        Divider()

        // アンサンブルチェック (副エンジンでこの区間だけ再認識)
        ensembleMenuItems(for: region)

        // 言語を変えて再書き起こし (faster-whisper)
        Menu("別の言語で再書き起こし") {
            retranscribeLanguageMenuItems(for: region)
        }

        Divider()

        Button("削除", role: .destructive) {
            deleteRegion(id: region.id)
        }
    }

    /// クロスチェックのメニュー項目。全副エンジンを一括で実行する。
    @ViewBuilder
    private func ensembleMenuItems(for region: CaptionRegion) -> some View {
        let primary = PreferencesStore.shared.sttEngine
        let hasCandidates = STTEngineType.allCases.contains { type in
            type != primary && (type == .parakeet || type == .qwen3)
        }
        if hasCandidates {
            let inFlight = transcriber.ensembleInFlight.contains(region.id)
            Button {
                transcriber.startCrossCheck(regionID: region.id, store: store)
            } label: {
                Label(
                    inFlight ? "別音声認識エンジンで解析中…" : "別音声認識エンジンで解析",
                    systemImage: "wand.and.sparkles"
                )
            }
            .disabled(inFlight)
            Divider()
        }
    }

    /// 言語を指定して再書き起こし (faster-whisper) のメニュー項目。
    @ViewBuilder
    private func retranscribeLanguageMenuItems(for region: CaptionRegion) -> some View {
        let languages: [(code: String, name: String)] = [
            ("fr", "フランス語"),
            ("en", "英語"),
            ("ja", "日本語"),
            ("de", "ドイツ語"),
            ("es", "スペイン語"),
            ("it", "イタリア語"),
            ("pt", "ポルトガル語"),
            ("ko", "韓国語"),
            ("zh", "中国語"),
            ("ru", "ロシア語"),
        ]
        ForEach(languages, id: \.code) { lang in
            Button(lang.name) {
                transcriber.retranscribeWithLanguage(
                    regionID: region.id,
                    language: lang.code,
                    store: store
                )
            }
        }
    }

    private func mergeRegion(at index: Int, withPrevious: Bool) {
        guard var state = store.project?.editor else { return }
        let regions = state.captionRegions.sorted { $0.startMs < $1.startMs }
        let neighborIndex = withPrevious ? index - 1 : index + 1
        guard index >= 0, index < regions.count,
              neighborIndex >= 0, neighborIndex < regions.count else { return }

        let current = regions[index]
        let neighbor = regions[neighborIndex]

        let mergedStartMs = min(current.startMs, neighbor.startMs)
        let mergedEndMs = max(current.endMs, neighbor.endMs)

        // テキスト結合: 時間順に並べる
        let first = current.startMs <= neighbor.startMs ? current : neighbor
        let second = current.startMs <= neighbor.startMs ? neighbor : current
        let mergedText: String = {
            let a = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let b = second.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if a.isEmpty { return b }
            if b.isEmpty { return a }
            if let last = a.unicodeScalars.last, last.isASCII {
                return a + " " + b
            }
            return a + b
        }()

        var merged = CaptionRegion(
            id: current.id,
            startMs: mergedStartMs,
            endMs: mergedEndMs,
            text: mergedText,
            isManuallyEdited: true,
            sourceLanguage: current.sourceLanguage,
            confidence: min(current.confidence, neighbor.confidence)
        )
        // 翻訳も同様に結合
        let tFirst = first.translatedText ?? ""
        let tSecond = second.translatedText ?? ""
        if !tFirst.isEmpty || !tSecond.isEmpty {
            let tA = tFirst.trimmingCharacters(in: .whitespacesAndNewlines)
            let tB = tSecond.trimmingCharacters(in: .whitespacesAndNewlines)
            if tA.isEmpty { merged.translatedText = tB }
            else if tB.isEmpty { merged.translatedText = tA }
            else if let last = tA.unicodeScalars.last, last.isASCII {
                merged.translatedText = tA + " " + tB
            } else {
                merged.translatedText = tA + tB
            }
        }

        state.captionRegions.removeAll { $0.id == current.id || $0.id == neighbor.id }
        state.captionRegions.append(merged)
        state.captionRegions.sort { $0.startMs < $1.startMs }
        store.commitState(state)
        timeline.select(itemID: merged.id)
    }

    // MARK: - リージョン分割

    /// テキスト中の最適な分割位置を探す。中間地点に最も近い区切り文字を返す。
    /// 優先順: 句点 > 読点/カンマ > スペース(英語)
    private func findBestSplitIndex(in text: String) -> String.Index? {
        let chars = Array(text)
        guard chars.count >= 4 else { return nil }
        let mid = chars.count / 2

        let sentenceChars: Set<Character> = [".", "。", "？", "！", "?", "!"]
        let commaChars: Set<Character> = [",", "、", ";", "；"]

        // 各カテゴリの区切り位置を、中間からの距離でソート
        var sentenceHits: [(idx: Int, dist: Int)] = []
        var commaHits: [(idx: Int, dist: Int)] = []
        var spaceHits: [(idx: Int, dist: Int)] = []

        for (i, ch) in chars.enumerated() {
            // 先頭・末尾付近（全体の10%以内）は候補から除外
            let margin = max(2, chars.count / 10)
            guard i >= margin, i < chars.count - margin else { continue }

            let dist = abs(i - mid)
            if sentenceChars.contains(ch) {
                sentenceHits.append((i, dist))
            } else if commaChars.contains(ch) {
                commaHits.append((i, dist))
            } else if ch == " " {
                spaceHits.append((i, dist))
            }
        }

        // 中間に最も近いものを優先
        let best: Int?
        if let hit = sentenceHits.min(by: { $0.dist < $1.dist }) {
            best = hit.idx
        } else if let hit = commaHits.min(by: { $0.dist < $1.dist }) {
            best = hit.idx
        } else if let hit = spaceHits.min(by: { $0.dist < $1.dist }) {
            // スペースの場合はスペース直前で切る（スペース自体は後半に含めない）
            return text.index(text.startIndex, offsetBy: hit.idx)
        } else {
            best = nil
        }

        guard let charIdx = best else { return nil }
        // 区切り文字の直後で分割（区切り文字は前半に含める）
        let splitAt = charIdx + 1
        guard splitAt < chars.count else { return nil }
        return text.index(text.startIndex, offsetBy: splitAt)
    }

    private func splitRegion(at index: Int) {
        guard var state = store.project?.editor else { return }
        let regions = state.captionRegions.sorted { $0.startMs < $1.startMs }
        guard index >= 0, index < regions.count else { return }

        let current = regions[index]
        let text = current.text
        guard let splitIdx = findBestSplitIndex(in: text) else { return }

        let headText = String(text[text.startIndex..<splitIdx]).trimmingCharacters(in: .whitespaces)
        let tailText = String(text[splitIdx...]).trimmingCharacters(in: .whitespaces)
        guard !headText.isEmpty, !tailText.isEmpty else { return }

        // 時間を文字比率で分割
        let totalChars = max(1, text.count)
        let headRatio = Double(headText.count) / Double(totalChars)
        let dur = current.endMs - current.startMs
        let splitMs = current.startMs + Int(Double(dur) * headRatio)

        var first = CaptionRegion(
            id: current.id,
            startMs: current.startMs,
            endMs: splitMs,
            text: headText,
            isManuallyEdited: true,
            sourceLanguage: current.sourceLanguage,
            confidence: current.confidence
        )

        var second = CaptionRegion(
            startMs: splitMs,
            endMs: current.endMs,
            text: tailText,
            isManuallyEdited: true,
            sourceLanguage: current.sourceLanguage,
            confidence: current.confidence
        )

        // 翻訳テキストも同様に分割
        if let translated = current.translatedText, !translated.isEmpty {
            if let tSplitIdx = findBestSplitIndex(in: translated) {
                let tHead = String(translated[translated.startIndex..<tSplitIdx])
                    .trimmingCharacters(in: .whitespaces)
                let tTail = String(translated[tSplitIdx...])
                    .trimmingCharacters(in: .whitespaces)
                first.translatedText = tHead.isEmpty ? nil : tHead
                second.translatedText = tTail.isEmpty ? nil : tTail
            } else {
                // 分割位置が見つからない場合は前半に全て残す
                first.translatedText = current.translatedText
            }
        }

        guard let stateIdx = state.captionRegions.firstIndex(where: { $0.id == current.id }) else { return }
        state.captionRegions[stateIdx] = first
        state.captionRegions.insert(second, at: stateIdx + 1)
        store.commitState(state)
        timeline.select(itemID: first.id)
    }

    /// テキストが分割可能か（何らかの区切り文字があるか）
    private func canSplitRegion(_ text: String) -> Bool {
        findBestSplitIndex(in: text) != nil
    }

    private static let sentenceTerminators: Set<Character> = [".", "。", "？", "！", "?", "!"]
    private static let commaBreakers: Set<Character> = [",", "、"]

    private func textHasBreak(_ text: String, using chars: Set<Character>) -> Bool {
        guard let idx = text.firstIndex(where: { chars.contains($0) }) else { return false }
        let after = text.index(after: idx)
        return after < text.endIndex
    }

    private func textHasSentenceBreak(_ text: String) -> Bool {
        textHasBreak(text, using: Self.sentenceTerminators)
    }

    /// 対象リージョンのテキストを最初の区切り文字で分割し、
    /// 前半を前のリージョンに結合、後半を現在のリージョンに残す。
    private func mergeUpToBreak(at index: Int, using chars: Set<Character>) {
        guard var state = store.project?.editor else { return }
        let regions = state.captionRegions.sorted { $0.startMs < $1.startMs }
        guard index > 0, index < regions.count else { return }

        let current = regions[index]
        let prev = regions[index - 1]

        let text = current.text
        guard let dotIdx = text.firstIndex(where: { chars.contains($0) }) else { return }
        let splitAfter = text.index(after: dotIdx)
        guard splitAfter < text.endIndex else {
            mergeRegion(at: index, withPrevious: true)
            return
        }

        let headPart = String(text[text.startIndex...dotIdx]).trimmingCharacters(in: .whitespaces)
        let tailPart = String(text[splitAfter...]).trimmingCharacters(in: .whitespaces)

        let totalChars = max(1, text.count)
        let headRatio = Double(headPart.count) / Double(totalChars)
        let dur = current.endMs - current.startMs
        let splitMs = current.startMs + Int(Double(dur) * headRatio)

        let prevText = prev.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedText: String
        if prevText.isEmpty {
            mergedText = headPart
        } else if let last = prevText.unicodeScalars.last, last.isASCII {
            mergedText = prevText + " " + headPart
        } else {
            mergedText = prevText + headPart
        }

        var updatedPrev = prev
        updatedPrev.text = mergedText
        updatedPrev.endMs = splitMs
        updatedPrev.isManuallyEdited = true

        var updatedCurrent = current
        updatedCurrent.text = tailPart
        updatedCurrent.startMs = splitMs
        updatedCurrent.isManuallyEdited = true

        guard let prevIdx = state.captionRegions.firstIndex(where: { $0.id == prev.id }),
              let curIdx = state.captionRegions.firstIndex(where: { $0.id == current.id }) else { return }
        state.captionRegions[prevIdx] = updatedPrev
        state.captionRegions[curIdx] = updatedCurrent
        store.commitState(state)
        timeline.select(itemID: updatedPrev.id)
    }

    /// 対象リージョンのテキストを最後の区切り文字で分割し、
    /// その後の部分を次のリージョンの先頭に結合する。
    private func mergeAfterBreak(at index: Int, using chars: Set<Character>) {
        guard var state = store.project?.editor else { return }
        let regions = state.captionRegions.sorted { $0.startMs < $1.startMs }
        guard index >= 0, index < regions.count - 1 else { return }

        let current = regions[index]
        let next = regions[index + 1]

        let text = current.text
        guard let dotIdx = text.lastIndex(where: { chars.contains($0) }) else { return }
        let splitAfter = text.index(after: dotIdx)
        guard splitAfter < text.endIndex else { return }

        let keepPart = String(text[text.startIndex...dotIdx]).trimmingCharacters(in: .whitespaces)
        let movePart = String(text[splitAfter...]).trimmingCharacters(in: .whitespaces)
        guard !movePart.isEmpty else { return }

        let totalChars = max(1, text.count)
        let keepRatio = Double(keepPart.count) / Double(totalChars)
        let dur = current.endMs - current.startMs
        let splitMs = current.startMs + Int(Double(dur) * keepRatio)

        let nextText = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedText: String
        if nextText.isEmpty {
            mergedText = movePart
        } else if let last = movePart.unicodeScalars.last, last.isASCII {
            mergedText = movePart + " " + nextText
        } else {
            mergedText = movePart + nextText
        }

        var updatedCurrent = current
        updatedCurrent.text = keepPart
        updatedCurrent.endMs = splitMs
        updatedCurrent.isManuallyEdited = true

        var updatedNext = next
        updatedNext.text = mergedText
        updatedNext.startMs = splitMs
        updatedNext.isManuallyEdited = true

        guard let curIdx = state.captionRegions.firstIndex(where: { $0.id == current.id }),
              let nextIdx = state.captionRegions.firstIndex(where: { $0.id == next.id }) else { return }
        state.captionRegions[curIdx] = updatedCurrent
        state.captionRegions[nextIdx] = updatedNext
        store.commitState(state)
        timeline.select(itemID: updatedNext.id)
    }

    private func mergeUpToSentenceEnd(at index: Int) {
        mergeUpToBreak(at: index, using: Self.sentenceTerminators)
    }

    private func mergeAfterSentenceEnd(at index: Int) {
        mergeAfterBreak(at: index, using: Self.sentenceTerminators)
    }

    private func deleteRegion(id: UUID) {
        guard var state = store.project?.editor else { return }
        state.captionRegions.removeAll { $0.id == id }
        store.commitState(state)
    }

    private func correctSingleRegion(at index: Int) {
        let regions = captionRegions
        let regionID = regions[index].id
        let domainHints = store.project?.editor.captionSettings.domainHints ?? []
        let endpoint = llmEndpoint
        let service = correctionService
        let dictStore = dictionaryStore

        transcriber.correctionInFlight.insert(regionID)

        Task {
            defer {
                Task { @MainActor [weak transcriber] in
                    transcriber?.correctionInFlight.remove(regionID)
                }
            }
            do {
                // Step 1: 辞書ベース校正
                var targetRegion = regions[index]
                let dictionary = dictStore.dictionary
                if !dictionary.entries.isEmpty {
                    let (correctedBatch, appliedIDs) = DictionaryCorrector.apply(
                        dictionary: dictionary,
                        to: [targetRegion]
                    )
                    targetRegion = correctedBatch[0]
                    for entryID in appliedIDs {
                        dictStore.incrementUseCount(id: entryID)
                    }
                }

                // Step 2: LLM 校正 (辞書エントリも keyTerms に含める)
                var allHints = domainHints
                for entry in dictionary.entries {
                    allHints.append("\(entry.wrong)→\(entry.correct)")
                }

                var regionsForLLM = regions
                regionsForLLM[index] = targetRegion

                let client = LLMClient(endpoint: endpoint)
                let corrected = try await service.correctSingle(
                    targetIndex: index,
                    allRegions: regionsForLLM,
                    domainHints: allHints,
                    client: client
                )
                guard var state = store.project?.editor,
                      let stateIdx = state.captionRegions.firstIndex(where: { $0.id == corrected.id }) else { return }
                state.captionRegions[stateIdx] = corrected
                store.commitState(state)
            } catch {
                AppLog.caption.error("単体 LLM 校正失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func translateSingleRegion(_ region: CaptionRegion) {
        let regions = captionRegions
        Task {
            do {
                let translated = try await translationService.translateSingle(
                    region, context: regions
                )
                guard var state = store.project?.editor,
                      let idx = state.captionRegions.firstIndex(where: { $0.id == translated.id }) else { return }
                state.captionRegions[idx] = translated
                store.commitState(state)
            } catch {
                translationService.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func captionRow(_ region: CaptionRegion) -> some View {
        HStack(spacing: 8) {
            // タイムスタンプ (開始 → 終了)
            Text("\(formatMs(region.startMs)) → \(formatMs(region.endMs))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 175, alignment: .leading)


            // 左カラム: 原文
            captionOriginalColumn(region)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 仕切り
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
                .padding(.vertical, 2)

            // 中央カラム
            columnContent(region, mode: middleColumnMode)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 仕切り
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
                .padding(.vertical, 2)

            // 右カラム
            columnContent(region, mode: rightColumnMode)
                .frame(maxWidth: .infinity, alignment: .leading)

            statusIcon(for: region)
        }
    }

    @ViewBuilder
    private func captionOriginalColumn(_ region: CaptionRegion) -> some View {
        if editingRegionID == region.id && editingTarget == .original {
            TextField("", text: $editingText, axis: .vertical)
                .focused($captionTextFocused)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.3))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.cyan.opacity(0.5), lineWidth: 1)
                )
                .onAppear { captionTextFocused = true }
                .onChange(of: captionTextFocused) { focused in
                    if !focused { commitCaptionEdit() }
                }
                .onSubmit { commitCaptionEdit() }
        } else {
            // 空 region でもクリック領域が狭くならないよう frame で広げる + contentShape
            Text(region.text.isEmpty ? "(空)" : region.text)
                .font(.system(size: 12))
                .foregroundStyle(region.text.isEmpty ? .secondary : EditorTheme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    captionContextMenu(for: region)
                }
        }
    }

    // MARK: - カラム切替

    private func columnPicker(selection: Binding<ColumnMode>) -> some View {
        HStack(spacing: 0) {
            ForEach(ColumnMode.allCases) { mode in
                let selected = selection.wrappedValue == mode
                Button {
                    selection.wrappedValue = mode
                } label: {
                    Text(mode.label)
                        .font(.system(size: 10, weight: selected ? .bold : .regular))
                        .foregroundStyle(selected ? columnAccent(mode) : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            selected
                            ? RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                            : nil
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func columnAccent(_ mode: ColumnMode) -> Color {
        switch mode {
        case .translation:    return Color.orange.opacity(0.9)
        case .preCorrection:  return Color.cyan.opacity(0.9)
        case .postCorrection: return Color.green.opacity(0.9)
        }
    }

    @ViewBuilder
    private func columnContent(_ region: CaptionRegion, mode: ColumnMode) -> some View {
        switch mode {
        case .translation:
            captionTranslatedColumn(region)
        case .preCorrection:
            captionPreCorrectionColumn(region)
        case .postCorrection:
            captionPostCorrectionColumn(region)
        }
    }

    @ViewBuilder
    private func captionPreCorrectionColumn(_ region: CaptionRegion) -> some View {
        let raw = region.originalRawText ?? ""
        let current = region.text
        if raw.isEmpty {
            Text(L10n.Timeline.noPreCorrection)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.4))
        } else if raw == current {
            Text(raw)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineLimit(2)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(raw)
                    .font(.system(size: 12))
                    .foregroundStyle(.cyan.opacity(0.9))
                    .lineLimit(2)
                    .strikethrough(true, color: .cyan.opacity(0.4))
            }
        }
    }

    @ViewBuilder
    private func captionPostCorrectionColumn(_ region: CaptionRegion) -> some View {
        let raw = region.originalRawText ?? ""
        let current = region.text
        if raw.isEmpty {
            Text(L10n.Timeline.uncorrected)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.4))
        } else if raw == current {
            Text(current)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineLimit(2)
        } else {
            Text(current)
                .font(.system(size: 12))
                .foregroundStyle(.green.opacity(0.9))
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func captionTranslatedColumn(_ region: CaptionRegion) -> some View {
        if editingRegionID == region.id && editingTarget == .translated {
            TextField("", text: $editingText, axis: .vertical)
                .focused($captionTextFocused)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.3))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                )
                .onAppear { captionTextFocused = true }
                .onChange(of: captionTextFocused) { focused in
                    if !focused { commitCaptionEdit() }
                }
                .onSubmit { commitCaptionEdit() }
        } else {
            let translated = region.translatedText ?? ""
            Text(translated.isEmpty ? "—" : translated)
                .font(.system(size: 12))
                .foregroundStyle(translated.isEmpty ? Color.secondary.opacity(0.4) : Color.orange.opacity(0.9))
                .lineLimit(2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    editingText = region.translatedText ?? ""
                    editingTarget = .translated
                    editingRegionID = region.id
                }
        }
    }

    @ViewBuilder
    private func statusIcon(for region: CaptionRegion) -> some View {
        if transcriber.retranscribeInFlight.contains(region.id)
            || transcriber.ensembleInFlight.contains(region.id)
            || transcriber.correctionInFlight.contains(region.id) {
            ProgressView()
                .controlSize(.mini)
        } else if region.isManuallyEdited {
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.cyan)
                .font(.system(size: 12))
        } else if region.confidence < 0.6 {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("字幕がありません")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("右パネルで「全体を自動合成」を押すか、「+ 追加」で空の字幕を挿入してください。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    // MARK: - Derived

    private var captionRegions: [CaptionRegion] {
        let regions = store.project?.editor.captionRegions ?? []
        return regions.sorted { $0.startMs < $1.startMs }
    }

    /// 字幕リスト (下部) 用のフィルタ版。
    /// 文字起こし実行中 (VAD で空 region 大量生成中 / ASR で順次 text 埋め中) は、
    /// まだテキストが入っていない region を一覧に表示しない (空 "(空)" 行が大量に並ぶのを防ぐ)。
    /// 処理完了後 (transcriber idle) は手動追加した空 region なども全て表示する。
    private var listCaptionRegions: [CaptionRegion] {
        if transcriber.isRunning {
            return captionRegions.filter { !$0.text.isEmpty }
        }
        return captionRegions
    }

    /// 波形未取得時のフォールバック尺 (ms)。PlaybackController の duration を使う。
    private var fallbackDurationMs: Int {
        let s = playback.duration.seconds
        return s.isFinite ? max(0, Int(s * 1000)) : 0
    }

    private func formatMs(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours   = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let millis  = ms % 1000
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, millis)
        }
        return String(format: "%02d:%02d.%03d", minutes, seconds, millis)
    }
}

// MARK: - WaveformMenuTarget

/// NSMenu の action ターゲット。representedObject に保持して menu 表示中の解放を防ぐ。
final class WaveformMenuTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func addCaptionAction(_ sender: Any?) { handler() }
    @objc func menuAction(_ sender: Any?) { handler() }
}
