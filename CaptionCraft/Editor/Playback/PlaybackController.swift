import AVFoundation
import Combine
import Foundation

/// プレビュー用の再生制御。
///
/// 2 つの再生モードを持つ:
/// 1. 通常再生: AVPlayer の rate 変更 + .spectral アルゴリズム (等速時)
/// 2. 聴き直しループ: Signalsmith Stretch で高品質ストレッチ → リージョンをループ再生
///    速度は 100%〜50% を 1% 刻みで変更可能。全速度をバックグラウンドでプリレンダーしてキャッシュする。
@MainActor
final class PlaybackController: ObservableObject {

    @Published private(set) var currentTime: CMTime = .zero
    @Published private(set) var duration:    CMTime = .zero
    @Published private(set) var isPlaying:   Bool   = false
    @Published private(set) var hasVideo:    Bool   = false

    /// 通常再生の速度 (0.5, 0.75, 1.0)。
    @Published private(set) var playbackSpeed: Double = 1.0

    /// 聴き直しループ中かどうか。
    @Published private(set) var isSlowLooping: Bool = false

    /// ループ再生の現在速度 (パーセント: 50〜100)。UI 表示用。
    @Published private(set) var loopSpeedPercent: Int = 100

    /// 実際に再生中のコンポジションの速度。mapToOriginalTime で使う。
    /// アイテム切り替え完了まで前の速度を保持する。
    private var effectiveSpeedPercent: Int = 100

    /// Rubber Band レンダリング中フラグ (初回レンダー用)。
    @Published private(set) var isRendering: Bool = false
    @Published private(set) var renderProgress: Double = 0

    /// キャッシュ済みの速度一覧 (UI でどこまで使えるか表示)。
    @Published private(set) var cachedSpeeds: Set<Int> = []

    /// ループ区間内の再生進捗 (0.0〜1.0)。波形ビューのプレイヘッド表示に使う。
    /// composition 時間から直接計算するので mapToOriginalTime の影響を受けない。
    @Published private(set) var loopProgress: Double = 0

    let player = AVPlayer()

    /// 聴き直しパネルの EQ プロセッサ。アイテム差し替え時に自動再アタッチする。
    var activeEQProcessor: ListenEQProcessor?

    var onMetadataLoaded: (@MainActor (CMTime, CGSize) -> Void)?

    private var timeObserver: Any?
    private var rateObserver: NSObjectProtocol?
    private var endObserver:  NSObjectProtocol?
    private var currentItem:  AVPlayerItem?

    private var sourceURL: URL?
    private var originalDuration: CMTime = .zero

    // ループ関連
    private(set) var loopRangeStart: Double = 0
    private(set) var loopRangeEnd: Double = 0
    private var savedTimeBeforeLoop: CMTime = .zero

    /// 全リージョンのキャッシュ。キーは "startMs_endMs"。
    private var regionCaches: [String: [Int: URL]] = [:]

    /// 現在アクティブなループのキャッシュキー。
    private var activeLoopKey: String = ""

    /// バックグラウンドキャッシュ生成タスク
    private var cacheTask: Task<Void, Never>?

    /// 現在のオンデマンドレンダータスク
    private var renderTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init() {
        installPeriodicObserver()
        installRateObserver()
    }

    deinit {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        if let rate     = rateObserver { NotificationCenter.default.removeObserver(rate) }
        if let end      = endObserver  { NotificationCenter.default.removeObserver(end)  }
    }

    // MARK: - Loading

    func load(url: URL) async {
        sourceURL = url
        playbackSpeed = 1.0
        stopSlowLoop()
        purgeCache()

        let asset = AVURLAsset(url: url)
        let item  = AVPlayerItem(asset: asset)

        var loadedDuration: CMTime  = .zero
        var loadedSize:     CGSize  = .zero

        do {
            loadedDuration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let track = tracks.first {
                let size = try await track.load(.naturalSize)
                let prefer = try await track.load(.preferredTransform)
                loadedSize = size.applying(prefer)
                loadedSize = CGSize(width: abs(loadedSize.width), height: abs(loadedSize.height))
            }
        } catch {
            NSLog("PlaybackController: asset load failed — %@", "\(error)")
        }

        item.audioTimePitchAlgorithm = .spectral

        replaceItem(item)
        installNormalEndObserver(item: item)

        duration = loadedDuration
        originalDuration = loadedDuration
        hasVideo = true

        onMetadataLoaded?(loadedDuration, loadedSize)
    }

    // MARK: - Playback

    func play() {
        guard player.currentItem != nil else { return }
        if duration.isValid
            && duration.seconds > 0
            && CMTimeCompare(currentTime, duration) >= 0 {
            player.seek(to: .zero)
            currentTime = .zero
        }
        if isSlowLooping {
            player.rate = 1.0
        } else {
            player.rate = Float(playbackSpeed)
        }
    }

    func pause() {
        player.pause()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(to time: CMTime) async {
        if isSlowLooping {
            let sec = time.seconds
            if sec < loopRangeStart - 0.5 || sec > loopRangeEnd + 0.5 {
                stopSlowLoop()
                await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = time
                return
            }
            let compTime = mapToCompositionTime(time)
            await player.seek(to: compTime, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = time
        } else {
            let clamped = clamp(time)
            await player.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = clamped
        }
    }

    func seek(to seconds: Double) async {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        await seek(to: t)
    }

    func stepForward() {
        guard let item = player.currentItem else { return }
        pause()
        item.step(byCount: 1)
        currentTime = item.currentTime()
    }

    func stepBackward() {
        guard let item = player.currentItem else { return }
        pause()
        item.step(byCount: -1)
        currentTime = item.currentTime()
    }

    // MARK: - 通常再生の速度変更 (AVPlayer rate + .spectral)

    func setSpeed(_ speed: Double) {
        guard !isSlowLooping else { return }
        playbackSpeed = speed
        if isPlaying {
            player.rate = Float(speed)
        }
    }

    // MARK: - 聴き直しループ

    /// 指定リージョンの聴き直しループを開始する。
    /// キャッシュがあれば即利用、なければ 100% で即再生してバックグラウンドでプリレンダー。
    func startSlowLoop(regionStartSec: Double, regionEndSec: Double) {
        guard let url = sourceURL else { return }
        guard regionEndSec > regionStartSec else { return }

        renderTask?.cancel()
        cacheTask?.cancel()
        let wasPlaying = isPlaying
        if wasPlaying { pause() }

        savedTimeBeforeLoop = currentTime
        isSlowLooping = true
        loopSpeedPercent = 100
        effectiveSpeedPercent = 100

        let padding = 0.5
        let rangeStart = max(0, regionStartSec - padding)
        let rangeEnd = min(originalDuration.seconds, regionEndSec + padding)
        loopRangeStart = rangeStart
        loopRangeEnd = rangeEnd
        activeLoopKey = cacheKey(rangeStart: rangeStart, rangeEnd: rangeEnd)

        // 既存キャッシュがあれば cachedSpeeds を復元
        let existing = regionCaches[activeLoopKey] ?? [:]
        cachedSpeeds = Set(existing.keys)
        cachedSpeeds.insert(100)

        // 100% は Rubber Band 不要。元動画をトリミングするだけで即再生。
        Task {
            do {
                let composition = try await buildTrimmedComposition(
                    videoSource: url,
                    rangeStart: rangeStart,
                    rangeEnd: rangeEnd
                )

                let item = AVPlayerItem(asset: composition)
                item.audioTimePitchAlgorithm = .spectral
                replaceItem(item)
                installLoopEndObserver(item: item)

                NSLog("SlowLoop: 100%% で即再生開始 (%.1f-%.1f秒, キャッシュ %d件)", rangeStart, rangeEnd, existing.count)
                player.rate = 1.0
            } catch {
                NSLog("SlowLoop start failed: %@", "\(error)")
                isSlowLooping = false
                return
            }

            // 未キャッシュの速度をバックグラウンドでレンダー
            startBackgroundCaching(url: url, rangeStart: rangeStart, rangeEnd: rangeEnd)
        }
    }

    /// ループ再生の速度を変更する (50〜100%)。
    /// loopSpeedPercent (UI 表示) は即更新。effectiveSpeedPercent (時間マッピング) はアイテム切り替え完了後に更新。
    func setLoopSpeed(_ percent: Int) {
        guard isSlowLooping else { return }
        let clamped = max(50, min(100, percent))
        guard clamped != loopSpeedPercent else { return }

        loopSpeedPercent = clamped

        if clamped == 100 {
            switchToSpeed100(percent: clamped)
            return
        }

        if regionCaches[activeLoopKey]?[clamped] != nil {
            switchToCachedSpeed(clamped)
        } else {
            // キャッシュなし: 現在の再生を維持したまま裏でレンダリング。完了後に切り替え。
            renderAndSwitchToSpeed(clamped)
        }
    }

    /// 聴き直しループを解除し、元のファイルに戻す。キャッシュは保持する。
    func stopSlowLoop() {
        guard isSlowLooping || isRendering else { return }
        renderTask?.cancel()
        // バックグラウンドキャッシュは止めない (続行して積む)
        isSlowLooping = false
        isRendering = false

        let wasPlaying = isPlaying
        if wasPlaying { pause() }

        guard let url = sourceURL else { return }

        let restoreTime = savedTimeBeforeLoop
        Task {
            await reloadOriginal(url: url)
            await seek(to: restoreTime)
        }
    }

    // MARK: - Private: 速度切り替え

    private func switchToSpeed100(percent: Int) {
        guard let url = sourceURL else { return }
        pause()

        Task {
            let composition = try await buildTrimmedComposition(
                videoSource: url,
                rangeStart: loopRangeStart,
                rangeEnd: loopRangeEnd
            )
            let item = AVPlayerItem(asset: composition)
            item.audioTimePitchAlgorithm = .spectral
            replaceItem(item)
            installLoopEndObserver(item: item)
            effectiveSpeedPercent = percent
            player.rate = 1.0
        }
    }

    private func switchToCachedSpeed(_ percent: Int) {
        guard let url = sourceURL,
              let cachedAudioURL = regionCaches[activeLoopKey]?[percent] else { return }
        pause()
        let speed = Double(percent) / 100.0

        Task {
            let composition = try await buildStretchedComposition(
                videoSource: url,
                stretchedAudioSource: cachedAudioURL,
                rangeStart: loopRangeStart,
                rangeEnd: loopRangeEnd,
                speed: speed
            )
            let item = AVPlayerItem(asset: composition)
            item.audioTimePitchAlgorithm = .spectral
            replaceItem(item)
            installLoopEndObserver(item: item)
            effectiveSpeedPercent = percent
            player.rate = 1.0
        }
    }

    /// キャッシュにない速度をレンダーして切り替える。
    /// 現在の再生は維持したまま裏でレンダリングし、完了後にのみアイテムを差し替える。
    private func renderAndSwitchToSpeed(_ percent: Int) {
        guard let url = sourceURL else { return }
        let speed = Double(percent) / 100.0

        isRendering = true
        renderProgress = 0

        renderTask?.cancel()
        renderTask = Task {
            do {
                let stretchedURL = try await AudioStretchRenderer.render(
                    sourceURL: url,
                    timeRatio: 1.0 / speed,
                    startTime: loopRangeStart,
                    endTime: loopRangeEnd,
                    onProgress: { [weak self] p in
                        Task { @MainActor [weak self] in
                            self?.renderProgress = p.fractionCompleted
                        }
                    }
                )

                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: stretchedURL)
                    return
                }

                regionCaches[activeLoopKey, default: [:]][percent] = stretchedURL
                cachedSpeeds.insert(percent)

                // レンダリング完了後、UI の loopSpeedPercent がまだこの速度なら切り替え
                // ユーザーが別の値に変えていたら切り替えない（キャッシュだけ残す）
                guard loopSpeedPercent == percent else {
                    isRendering = false
                    return
                }

                let composition = try await buildStretchedComposition(
                    videoSource: url,
                    stretchedAudioSource: stretchedURL,
                    rangeStart: loopRangeStart,
                    rangeEnd: loopRangeEnd,
                    speed: speed
                )
                let item = AVPlayerItem(asset: composition)
                item.audioTimePitchAlgorithm = .spectral
                replaceItem(item)
                installLoopEndObserver(item: item)

                effectiveSpeedPercent = percent
                isRendering = false
                player.rate = 1.0
            } catch {
                NSLog("SlowLoop render failed: %@", "\(error)")
                isRendering = false
            }
        }
    }

    // MARK: - Private: バックグラウンドキャッシュ

    /// 99%〜50% をバックグラウンドで順次レンダーしてキャッシュに積む。
    private func startBackgroundCaching(url: URL, rangeStart: Double, rangeEnd: Double) {
        let key = cacheKey(rangeStart: rangeStart, rangeEnd: rangeEnd)
        cacheTask?.cancel()
        cacheTask = Task {
            for percent in stride(from: 99, through: 50, by: -1) {
                guard !Task.isCancelled else { return }
                guard regionCaches[key]?[percent] == nil else { continue }

                let speed = Double(percent) / 100.0
                do {
                    let stretchedURL = try await AudioStretchRenderer.render(
                        sourceURL: url,
                        timeRatio: 1.0 / speed,
                        startTime: rangeStart,
                        endTime: rangeEnd,
                        onProgress: nil
                    )

                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: stretchedURL)
                        return
                    }

                    regionCaches[key, default: [:]][percent] = stretchedURL
                    cachedSpeeds.insert(percent)
                    NSLog("SlowLoop cache: %d%% 完了", percent)
                } catch {
                    NSLog("SlowLoop cache %d%% failed: %@", percent, "\(error)")
                }
            }
            NSLog("SlowLoop: 全キャッシュ完了 (%d件)", regionCaches[key]?.count ?? 0)
        }
    }

    // MARK: - Private: アイテム管理

    private func replaceItem(_ item: AVPlayerItem) {
        if let end = endObserver {
            NotificationCenter.default.removeObserver(end)
            endObserver = nil
        }
        player.replaceCurrentItem(with: item)
        currentItem = item

        if let eq = activeEQProcessor, eq.isActive {
            eq.attach(to: item)
        }
    }

    private func installNormalEndObserver(item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.seek(to: .zero)
                self.pause()
            }
        }
    }

    private func installLoopEndObserver(item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.player.rate = 1.0
            }
        }
    }

    private func reloadOriginal(url: URL) async {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral

        replaceItem(item)
        installNormalEndObserver(item: item)

        duration = originalDuration
        loopRangeStart = 0
        loopRangeEnd = 0
    }

    // MARK: - Private: コンポジション構築

    /// 100% 用: 元動画をトリミングするだけ (ストレッチなし)。
    private func buildTrimmedComposition(
        videoSource: URL,
        rangeStart: Double,
        rangeEnd: Double
    ) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: videoSource)
        let composition = AVMutableComposition()

        let srcStart = CMTime(seconds: rangeStart, preferredTimescale: 600)
        let srcDur = CMTime(seconds: rangeEnd - rangeStart, preferredTimescale: 600)
        let srcRange = CMTimeRange(start: srcStart, duration: srcDur)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if let srcTrack = videoTracks.first {
            let compTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )!
            try compTrack.insertTimeRange(srcRange, of: srcTrack, at: .zero)
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let srcTrack = audioTracks.first {
            let compTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )!
            try compTrack.insertTimeRange(srcRange, of: srcTrack, at: .zero)
        }

        return composition
    }

    /// < 100% 用: 映像をスケール + Rubber Band 音声を合成。
    private func buildStretchedComposition(
        videoSource: URL,
        stretchedAudioSource: URL,
        rangeStart: Double,
        rangeEnd: Double,
        speed: Double
    ) async throws -> AVMutableComposition {
        let videoAsset = AVURLAsset(url: videoSource)
        let audioAsset = AVURLAsset(url: stretchedAudioSource)

        let composition = AVMutableComposition()
        let rangeDuration = rangeEnd - rangeStart
        let stretchedDuration = rangeDuration / speed

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        if let srcVideoTrack = videoTracks.first {
            let compVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )!

            let srcStart = CMTime(seconds: rangeStart, preferredTimescale: 600)
            let srcDur = CMTime(seconds: rangeDuration, preferredTimescale: 600)
            let srcRange = CMTimeRange(start: srcStart, duration: srcDur)

            try compVideoTrack.insertTimeRange(srcRange, of: srcVideoTrack, at: .zero)

            let insertedRange = CMTimeRange(start: .zero, duration: srcDur)
            let targetDur = CMTime(seconds: stretchedDuration, preferredTimescale: 600)
            compVideoTrack.scaleTimeRange(insertedRange, toDuration: targetDur)
        }

        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        if let srcAudioTrack = audioTracks.first {
            let compAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )!

            let audioDuration = try await audioAsset.load(.duration)
            let audioRange = CMTimeRange(start: .zero, duration: audioDuration)
            try compAudioTrack.insertTimeRange(audioRange, of: srcAudioTrack, at: .zero)
        }

        return composition
    }

    // MARK: - キャッシュ管理

    /// キャッシュの合計件数。
    var totalCachedCount: Int {
        regionCaches.values.reduce(0) { $0 + $1.count }
    }

    /// 全キャッシュを削除する (ユーザー明示操作)。
    func purgeCache() {
        cacheTask?.cancel()
        for (_, cache) in regionCaches {
            for (_, url) in cache {
                try? FileManager.default.removeItem(at: url)
            }
        }
        regionCaches.removeAll()
        cachedSpeeds.removeAll()
        NSLog("SlowLoop: キャッシュを全削除")
    }

    private func cacheKey(rangeStart: Double, rangeEnd: Double) -> String {
        let startMs = Int(rangeStart * 1000)
        let endMs = Int(rangeEnd * 1000)
        return "\(startMs)_\(endMs)"
    }

    // MARK: - Private: 時刻変換

    private func installPeriodicObserver() {
        let interval = CMTime(value: 1, timescale: 60)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isSlowLooping {
                    self.currentTime = self.mapToOriginalTime(time)
                    let compositionSec = time.seconds
                    let compositionDuration = self.player.currentItem?.duration.seconds ?? 0
                    if compositionDuration > 0, compositionSec.isFinite {
                        self.loopProgress = max(0, min(1, compositionSec / compositionDuration))
                    }
                } else {
                    self.currentTime = time
                }
            }
        }
    }

    /// コンポジション時間 → 元動画の時刻 (ループ再生用)。
    /// effectiveSpeedPercent (実際に再生中のコンポジションの速度) を使う。
    private func mapToOriginalTime(_ compositionTime: CMTime) -> CMTime {
        let sec = compositionTime.seconds
        guard sec.isFinite else { return compositionTime }
        let speed = Double(effectiveSpeedPercent) / 100.0
        let originalSec = loopRangeStart + sec * speed
        return CMTime(seconds: originalSec, preferredTimescale: 600)
    }

    /// 元動画の時刻 → コンポジション時間 (ループ再生用)。
    /// effectiveSpeedPercent (実際に再生中のコンポジションの速度) を使う。
    private func mapToCompositionTime(_ originalTime: CMTime) -> CMTime {
        let sec = originalTime.seconds
        guard sec.isFinite else { return originalTime }
        let speed = Double(effectiveSpeedPercent) / 100.0
        let compositionSec = (sec - loopRangeStart) / speed
        return CMTime(seconds: max(0, compositionSec), preferredTimescale: 600)
    }

    private func installRateObserver() {
        rateObserver = NotificationCenter.default.addObserver(
            forName:  AVPlayer.rateDidChangeNotification,
            object:   player,
            queue:    .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    private func clamp(_ time: CMTime) -> CMTime {
        guard duration.isValid, duration.seconds > 0 else { return .zero }
        if CMTimeCompare(time, .zero) < 0 { return .zero }
        if CMTimeCompare(time, duration) > 0 { return duration }
        return time
    }
}
