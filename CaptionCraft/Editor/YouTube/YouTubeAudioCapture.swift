import AVFoundation
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit を使ってアプリ自身のウィンドウから音声をキャプチャし、WAV ファイルに保存する。
@MainActor
final class YouTubeAudioCapture: NSObject, ObservableObject {

    static func intent() -> String {
        """
        役割: YouTube モードで再生中の音声を ScreenCaptureKit でキャプチャし、
        PCM Float32 WAV ファイルとして書き出す。出力ファイルは既存の
        CaptionTranscriber パイプライン (AudioFileLoader → VAD → ASR) にそのまま渡せる。

        成熟度: experimental

        依存:
        - macOS 14+ (SCContentFilter(desktopIndependentWindow:))
        - TCC 画面収録権限 (NSScreenCaptureUsageDescription)

        変更時の注意:
        - SCStreamOutput のコールバックはバックグラウンドスレッドで呼ばれる。
          audioWriter は AudioWriterBox (sendable wrapper) 経由でアクセスする。
        """
    }

    // MARK: - Published state

    @Published var isCapturing = false
    @Published var capturedDuration: Double = 0
    @Published var capturedFileURL: URL?
    @Published var permissionDenied = false
    @Published var errorMessage: String?

    // MARK: - Private

    private var stream: SCStream?
    private var outputURL: URL?
    private var captureStartTime: Date?
    private var durationTimer: Timer?

    /// バックグラウンドスレッドから安全にアクセスするための Sendable ラッパー。
    private let writerBox = AudioWriterBox()

    // MARK: - Capture lifecycle

    func startCapture() async {
        errorMessage = nil
        permissionDenied = false

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            permissionDenied = true
            errorMessage = "画面収録の権限がありません。システム設定→プライバシーとセキュリティ→画面収録 で CaptionCraft を許可してください。"
            return
        }

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == bundleID && $0.isOnScreen
        }) else {
            errorMessage = "キャプチャ対象のウィンドウが見つかりません"
            return
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.width = 2
        config.height = 2

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube_capture_\(UUID().uuidString).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: true
        )!
        do {
            let writer = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            writerBox.set(writer)
        } catch {
            errorMessage = "音声ファイルの作成に失敗: \(error.localizedDescription)"
            return
        }
        outputURL = fileURL

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            try await scStream.startCapture()
        } catch {
            errorMessage = "キャプチャの開始に失敗: \(error.localizedDescription)"
            return
        }

        stream = scStream
        isCapturing = true
        capturedDuration = 0
        captureStartTime = Date()

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.captureStartTime else { return }
                self.capturedDuration = Date().timeIntervalSince(start)
            }
        }
    }

    func stopCapture() async -> URL? {
        durationTimer?.invalidate()
        durationTimer = nil

        if let scStream = stream {
            try? await scStream.stopCapture()
        }
        stream = nil
        writerBox.set(nil)

        isCapturing = false
        capturedFileURL = outputURL
        return outputURL
    }

    func reset() {
        if let url = capturedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        capturedFileURL = nil
        capturedDuration = 0
        outputURL = nil
        errorMessage = nil
    }
}

// MARK: - SCStreamOutput

extension YouTubeAudioCapture: SCStreamOutput {

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        guard let avFormat = AVAudioFormat(streamDescription: asbd) else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // CMBlockBuffer から PCMBuffer へデータコピー
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == noErr, let srcPtr = dataPointer else { return }

        if let dstData = pcmBuffer.audioBufferList.pointee.mBuffers.mData {
            let byteCount = min(totalLength, Int(pcmBuffer.audioBufferList.pointee.mBuffers.mDataByteSize))
            dstData.copyMemory(from: srcPtr, byteCount: byteCount)
        }

        writerBox.write(pcmBuffer)
    }
}

// MARK: - AudioWriterBox

/// `AVAudioFile` を nonisolated コンテキストから安全にアクセスするための Sendable ラッパー。
private final class AudioWriterBox: @unchecked Sendable {
    private var writer: AVAudioFile?
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    init() {
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func set(_ newWriter: AVAudioFile?) {
        os_unfair_lock_lock(lock)
        writer = newWriter
        os_unfair_lock_unlock(lock)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let w = writer else { return }
        try? w.write(from: buffer)
    }
}
