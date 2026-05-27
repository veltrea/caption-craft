import AVFoundation
import MediaToolbox

/// AVPlayer の音声パイプラインに 2 段階 EQ を挿入するプロセッサ。
/// Stage 1: パラメトリック EQ (音声学ベース 6 バンド — 声の強調)
/// Stage 2: グラフィック EQ (10 バンド 1 オクターブ幅 — ノイズカット)
/// MTAudioProcessingTap で AVPlayerItem の音声を直接加工する。
@MainActor
final class ListenEQProcessor: ObservableObject {
    static func intent() -> String { """
    役割: AVPlayer の音声出力パイプラインに 2 段階 EQ を挿入する。
          Stage 1 = パラメトリック EQ (SII 準拠 6 バンド、声の強調)
          Stage 2 = グラフィック EQ (1 オクターブ 10 バンド、ノイズカット)
          MTAudioProcessingTap で出力直前の音声バッファに biquad EQ を適用。
    成熟度: experimental
    依存: PlaybackController (AVPlayerItem 管理)
    変更時の注意: attach() は AVPlayerItem 差し替えのたびに呼び直す必要がある。
                 PlaybackController.replaceItem() から自動で再アタッチする。
    """ }

    // MARK: - EQ バンド定義

    enum FilterType: Int {
        case highPass = 0
        case bell = 1
        case highShelf = 2
    }

    struct EQBand: Identifiable {
        let id: Int
        let label: String
        let detail: String
        var frequency: Float
        var q: Float
        let filterType: FilterType
        var gain: Float = 0
    }

    // Stage 1: パラメトリック EQ — 音声学ベース 6 バンド
    nonisolated static let parametricCount = 6
    nonisolated static let defaultParametricBands: [EQBand] = [
        EQBand(id: 0, label: "Sub",       detail: "低域カット",   frequency: 80,   q: 0.707, filterType: .highPass),
        EQBand(id: 1, label: "Body",      detail: "声の太さ",    frequency: 250,  q: 1.0,   filterType: .bell),
        EQBand(id: 2, label: "Presence",  detail: "明瞭度",     frequency: 1500, q: 1.5,   filterType: .bell),
        EQBand(id: 3, label: "Clarity",   detail: "子音",       frequency: 3500, q: 1.2,   filterType: .bell),
        EQBand(id: 4, label: "Sibilance", detail: "摩擦音",     frequency: 6500, q: 2.0,   filterType: .bell),
        EQBand(id: 5, label: "Air",       detail: "気息・かすれ", frequency: 10000, q: 0.707, filterType: .highShelf),
    ]

    // Stage 2: グラフィック EQ — 1 オクターブ幅 10 バンド (Q=1.414 ≈ 1 oct)
    nonisolated static let graphicCount = 10
    nonisolated static let defaultGraphicBands: [EQBand] = [
        EQBand(id: 0,  label: "31",   detail: "31 Hz",    frequency: 31.25, q: 1.414, filterType: .bell),
        EQBand(id: 1,  label: "63",   detail: "63 Hz",    frequency: 62.5,  q: 1.414, filterType: .bell),
        EQBand(id: 2,  label: "125",  detail: "125 Hz",   frequency: 125,   q: 1.414, filterType: .bell),
        EQBand(id: 3,  label: "250",  detail: "250 Hz",   frequency: 250,   q: 1.414, filterType: .bell),
        EQBand(id: 4,  label: "500",  detail: "500 Hz",   frequency: 500,   q: 1.414, filterType: .bell),
        EQBand(id: 5,  label: "1k",   detail: "1 kHz",    frequency: 1000,  q: 1.414, filterType: .bell),
        EQBand(id: 6,  label: "2k",   detail: "2 kHz",    frequency: 2000,  q: 1.414, filterType: .bell),
        EQBand(id: 7,  label: "4k",   detail: "4 kHz",    frequency: 4000,  q: 1.414, filterType: .bell),
        EQBand(id: 8,  label: "8k",   detail: "8 kHz",    frequency: 8000,  q: 1.414, filterType: .bell),
        EQBand(id: 9,  label: "16k",  detail: "16 kHz",   frequency: 16000, q: 1.414, filterType: .bell),
    ]

    nonisolated static let totalFilterCount = parametricCount + graphicCount

    // MARK: - Published

    @Published var parametricBands: [EQBand] = ListenEQProcessor.defaultParametricBands
    @Published var graphicBands: [EQBand] = ListenEQProcessor.defaultGraphicBands
    @Published private(set) var isActive = false

    // MARK: - Audio thread 共有コンテキスト

    private let context: UnsafeMutablePointer<EQTapContext>

    init() {
        context = .allocate(capacity: 1)
        context.initialize(to: EQTapContext())
    }

    deinit {
        context.deinitialize(count: 1)
        context.deallocate()
    }

    // MARK: - パラメトリック EQ 制御

    func setParametricGain(_ gain: Float, forBand index: Int) {
        guard index >= 0, index < Self.parametricCount else { return }
        parametricBands[index].gain = gain
        os_unfair_lock_lock(&context.pointee.lock)
        context.pointee.gains[index] = gain
        context.pointee.needsRecalc = true
        os_unfair_lock_unlock(&context.pointee.lock)
    }

    func setParametricFrequency(_ freq: Float, forBand index: Int) {
        guard index >= 0, index < Self.parametricCount else { return }
        parametricBands[index].frequency = freq
        os_unfair_lock_lock(&context.pointee.lock)
        context.pointee.frequencies[index] = freq
        context.pointee.needsRecalc = true
        os_unfair_lock_unlock(&context.pointee.lock)
    }

    func setParametricQ(_ q: Float, forBand index: Int) {
        guard index >= 0, index < Self.parametricCount else { return }
        parametricBands[index].q = q
        os_unfair_lock_lock(&context.pointee.lock)
        context.pointee.qs[index] = q
        context.pointee.needsRecalc = true
        os_unfair_lock_unlock(&context.pointee.lock)
    }

    func resetParametricEQ() {
        let defaults = Self.defaultParametricBands
        os_unfair_lock_lock(&context.pointee.lock)
        for i in 0..<Self.parametricCount {
            parametricBands[i].gain = 0
            parametricBands[i].frequency = defaults[i].frequency
            parametricBands[i].q = defaults[i].q
            context.pointee.gains[i] = 0
            context.pointee.frequencies[i] = defaults[i].frequency
            context.pointee.qs[i] = defaults[i].q
        }
        context.pointee.needsRecalc = true
        os_unfair_lock_unlock(&context.pointee.lock)
    }

    // MARK: - グラフィック EQ 制御

    func setGraphicGain(_ gain: Float, forBand index: Int) {
        guard index >= 0, index < Self.graphicCount else { return }
        graphicBands[index].gain = gain
        let ctxIndex = Self.parametricCount + index
        os_unfair_lock_lock(&context.pointee.lock)
        context.pointee.gains[ctxIndex] = gain
        context.pointee.needsRecalc = true
        os_unfair_lock_unlock(&context.pointee.lock)
    }

    func resetGraphicEQ() {
        os_unfair_lock_lock(&context.pointee.lock)
        for i in 0..<Self.graphicCount {
            graphicBands[i].gain = 0
            context.pointee.gains[Self.parametricCount + i] = 0
        }
        context.pointee.needsRecalc = true
        os_unfair_lock_unlock(&context.pointee.lock)
    }

    func resetAllEQ() {
        os_unfair_lock_lock(&context.pointee.lock)
        for i in 0..<Self.parametricCount {
            parametricBands[i].gain = 0
            context.pointee.gains[i] = 0
        }
        for i in 0..<Self.graphicCount {
            graphicBands[i].gain = 0
            context.pointee.gains[Self.parametricCount + i] = 0
        }
        context.pointee.needsRecalc = true
        os_unfair_lock_unlock(&context.pointee.lock)
    }

    // MARK: - AVPlayerItem へのアタッチ

    func attach(to item: AVPlayerItem) {
        item.audioMix = nil

        // アイテム切り替え時にフィルタ状態をリセット（残留値による不連続ノイズ防止）
        os_unfair_lock_lock(&context.pointee.lock)
        for i in 0..<Self.totalFilterCount { context.pointee.filters[i].reset() }
        os_unfair_lock_unlock(&context.pointee.lock)

        let audioTracks = item.asset.tracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            NSLog("ListenEQProcessor: 音声トラックなし")
            return
        }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(context),
            init: eqTapInit,
            finalize: eqTapFinalize,
            prepare: eqTapPrepare,
            unprepare: eqTapUnprepare,
            process: eqTapProcess
        )

        var tapRef: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tapRef
        )
        guard status == noErr, let tap = tapRef else {
            NSLog("ListenEQProcessor: tap 作成失敗 status=%d", status)
            return
        }

        let params = AVMutableAudioMixInputParameters(track: audioTrack)
        params.audioTapProcessor = tap.takeRetainedValue()

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix

        isActive = true
        NSLog("ListenEQProcessor: EQ アタッチ完了")
    }

    func detach(from item: AVPlayerItem) {
        item.audioMix = nil
        isActive = false

        os_unfair_lock_lock(&context.pointee.lock)
        for i in 0..<Self.totalFilterCount { context.pointee.filters[i].reset() }
        os_unfair_lock_unlock(&context.pointee.lock)
    }
}

// MARK: - Biquad フィルタ

private struct BiquadCoeffs {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0
}

private struct BiquadState {
    var coeffs = BiquadCoeffs()
    var x1: Float = 0, x2: Float = 0
    var y1: Float = 0, y2: Float = 0

    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    mutating func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        let b0 = coeffs.b0, b1 = coeffs.b1, b2 = coeffs.b2
        let a1 = coeffs.a1, a2 = coeffs.a2

        if b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0 { return }

        var lx1 = self.x1, lx2 = self.x2
        var ly1 = self.y1, ly2 = self.y2

        for i in 0..<count {
            let x0 = buffer[i]
            let y0 = b0 * x0 + b1 * lx1 + b2 * lx2 - a1 * ly1 - a2 * ly2
            lx2 = lx1; lx1 = x0
            ly2 = ly1; ly1 = y0
            buffer[i] = y0
        }

        // デノーマル数フラッシュ: 極小値がCPU負荷とノイズの原因になる
        self.x1 = flushDenormal(lx1); self.x2 = flushDenormal(lx2)
        self.y1 = flushDenormal(ly1); self.y2 = flushDenormal(ly2)
    }

    private func flushDenormal(_ v: Float) -> Float {
        fabsf(v) < 1.0e-15 ? 0 : v
    }
}

// MARK: - Audio thread コンテキスト

private let kTotalFilters = ListenEQProcessor.totalFilterCount

private struct EQTapContext {
    var lock = os_unfair_lock()
    var gains: [Float] = Array(repeating: 0, count: kTotalFilters)
    var frequencies: [Float] = {
        let p = ListenEQProcessor.defaultParametricBands.map(\.frequency)
        let g = ListenEQProcessor.defaultGraphicBands.map(\.frequency)
        return p + g
    }()
    var qs: [Float] = {
        let p = ListenEQProcessor.defaultParametricBands.map(\.q)
        let g = ListenEQProcessor.defaultGraphicBands.map(\.q)
        return p + g
    }()
    var filterTypes: [ListenEQProcessor.FilterType] = {
        let p = ListenEQProcessor.defaultParametricBands.map(\.filterType)
        let g = ListenEQProcessor.defaultGraphicBands.map(\.filterType)
        return p + g
    }()
    var filters: [BiquadState] = Array(repeating: BiquadState(), count: kTotalFilters)
    var sampleRate: Float = 44100
    var needsRecalc = true

    mutating func recalcIfNeeded() {
        guard needsRecalc else { return }
        needsRecalc = false

        for i in 0..<kTotalFilters {
            let freq = frequencies[i]
            let q = qs[i]
            let gain = gains[i]
            switch filterTypes[i] {
            case .highPass:
                filters[i].coeffs = Self.highPass(frequency: freq, q: q, gain: gain, sampleRate: sampleRate)
            case .bell:
                filters[i].coeffs = Self.peakingEQ(frequency: freq, q: q, gain: gain, sampleRate: sampleRate)
            case .highShelf:
                filters[i].coeffs = Self.highShelf(frequency: freq, gain: gain, sampleRate: sampleRate)
            }
        }
    }

    // Peaking EQ (Bell)
    static func peakingEQ(frequency: Float, q: Float, gain: Float, sampleRate: Float) -> BiquadCoeffs {
        guard gain != 0 else { return BiquadCoeffs() }
        let A = powf(10, gain / 40.0)
        let w0 = 2.0 * Float.pi * frequency / sampleRate
        let sinW0 = sinf(w0), cosW0 = cosf(w0)
        let alpha = sinW0 / (2.0 * q)
        let a0 = 1 + alpha / A
        return BiquadCoeffs(
            b0: (1 + alpha * A) / a0, b1: (-2 * cosW0) / a0, b2: (1 - alpha * A) / a0,
            a1: (-2 * cosW0) / a0, a2: (1 - alpha / A) / a0
        )
    }

    // High-pass filter (gain をカットの深さとして使う: 0=オフ, 正=カット有効)
    static func highPass(frequency: Float, q: Float, gain: Float, sampleRate: Float) -> BiquadCoeffs {
        guard gain != 0 else { return BiquadCoeffs() }
        // gain > 0 で HPF 有効。gain の大きさでカットオフ周波数を上にシフト。
        let cutoff = frequency * (1.0 + gain / 12.0)
        let w0 = 2.0 * Float.pi * cutoff / sampleRate
        let sinW0 = sinf(w0), cosW0 = cosf(w0)
        let alpha = sinW0 / (2.0 * q)
        let a0 = 1 + alpha
        return BiquadCoeffs(
            b0: ((1 + cosW0) / 2) / a0, b1: (-(1 + cosW0)) / a0, b2: ((1 + cosW0) / 2) / a0,
            a1: (-2 * cosW0) / a0, a2: (1 - alpha) / a0
        )
    }

    // High shelf
    static func highShelf(frequency: Float, gain: Float, sampleRate: Float) -> BiquadCoeffs {
        guard gain != 0 else { return BiquadCoeffs() }
        let A = powf(10, gain / 40.0)
        let w0 = 2.0 * Float.pi * frequency / sampleRate
        let sinW0 = sinf(w0), cosW0 = cosf(w0)
        let alpha = sinW0 / 2.0 * sqrtf((A + 1.0 / A) * 2.0)
        let sqrtA2alpha = 2.0 * sqrtf(A) * alpha
        let a0 = (A + 1) - (A - 1) * cosW0 + sqrtA2alpha
        return BiquadCoeffs(
            b0: (A * ((A + 1) + (A - 1) * cosW0 + sqrtA2alpha)) / a0,
            b1: (-2 * A * ((A - 1) + (A + 1) * cosW0)) / a0,
            b2: (A * ((A + 1) + (A - 1) * cosW0 - sqrtA2alpha)) / a0,
            a1: (2 * ((A - 1) - (A + 1) * cosW0)) / a0,
            a2: ((A + 1) - (A - 1) * cosW0 - sqrtA2alpha) / a0
        )
    }
}

// MARK: - MTAudioProcessingTap コールバック

private let eqTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let eqTapFinalize: MTAudioProcessingTapFinalizeCallback = { _ in
}

private let eqTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    let ctx = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: EQTapContext.self)
    os_unfair_lock_lock(&ctx.pointee.lock)
    ctx.pointee.sampleRate = Float(processingFormat.pointee.mSampleRate)
    ctx.pointee.needsRecalc = true
    // 新しい tap セッション開始時にフィルタ状態をクリア
    for i in 0..<kTotalFilters { ctx.pointee.filters[i].reset() }
    os_unfair_lock_unlock(&ctx.pointee.lock)
    NSLog("ListenEQ: prepare sr=%.0f ch=%d",
          processingFormat.pointee.mSampleRate,
          processingFormat.pointee.mChannelsPerFrame)
}

private let eqTapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in
}

private let eqTapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
    )
    guard status == noErr else { return }

    let ctx = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: EQTapContext.self)
    os_unfair_lock_lock(&ctx.pointee.lock)
    ctx.pointee.recalcIfNeeded()

    let bufPtr = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    for buf in bufPtr {
        guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let frameCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        for f in 0..<kTotalFilters {
            ctx.pointee.filters[f].process(data, count: frameCount)
        }
    }

    os_unfair_lock_unlock(&ctx.pointee.lock)
}
