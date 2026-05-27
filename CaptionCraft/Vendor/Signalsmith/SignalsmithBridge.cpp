#include "signalsmith-stretch.h"
#include "SignalsmithBridge.h"

#include <cstring>
#include <vector>

struct SSStretcherImpl {
    signalsmith::stretch::SignalsmithStretch<float> stretcher;
    int sampleRate;
    int channels;
};

extern "C" {

SSStretcher ss_create(int sampleRate, int channels) {
    auto* impl = new SSStretcherImpl();
    impl->sampleRate = sampleRate;
    impl->channels = channels;
    impl->stretcher.presetDefault(channels, static_cast<float>(sampleRate));
    return static_cast<SSStretcher>(impl);
}

void ss_destroy(SSStretcher s) {
    delete static_cast<SSStretcherImpl*>(s);
}

int ss_stretch_offline(
    SSStretcher s,
    const float* const* input,
    int inputFrames,
    float** output,
    int outputFrames,
    double timeRatio,
    int channels
) {
    auto* impl = static_cast<SSStretcherImpl*>(s);
    impl->stretcher.reset();

    // Signalsmith の process() はブロック単位で入出力する。
    // オフライン処理: 入力全体を一定ブロックずつ送り、出力を回収する。
    // playbackRate = 1/timeRatio (timeRatio=2.0 → playbackRate=0.5 → 半速再生)
    const double playbackRate = 1.0 / timeRatio;

    // seek で初期状態を設定 (レイテンシ補償)
    int latencyIn = impl->stretcher.inputLatency();
    int latencyOut = impl->stretcher.outputLatency();

    // 入力の先頭を seek に渡してプリロールする
    int seekSamples = latencyIn + static_cast<int>(playbackRate * latencyOut) + 1;
    if (seekSamples > inputFrames) seekSamples = inputFrames;

    std::vector<const float*> seekPtrs(channels);
    for (int ch = 0; ch < channels; ++ch) {
        seekPtrs[ch] = input[ch];
    }
    impl->stretcher.seek(seekPtrs.data(), seekSamples, playbackRate);

    // ブロック単位で処理
    const int blockSize = 1024;
    int inputOffset = 0;
    int outputOffset = 0;

    // 一時バッファ (ブロック単位の入出力ポインタ)
    std::vector<std::vector<float>> inBufs(channels);
    std::vector<std::vector<float>> outBufs(channels);
    std::vector<const float*> inPtrs(channels);
    std::vector<float*> outPtrs(channels);

    for (int ch = 0; ch < channels; ++ch) {
        inBufs[ch].resize(blockSize, 0.0f);
        outBufs[ch].resize(blockSize, 0.0f);
    }

    while (outputOffset < outputFrames) {
        // 今回の入力・出力ブロックサイズを計算
        int remainOut = outputFrames - outputOffset;
        int outBlock = (remainOut < blockSize) ? remainOut : blockSize;
        int inBlock = static_cast<int>(outBlock * playbackRate + 0.5);
        if (inBlock < 1) inBlock = 1;

        int remainIn = inputFrames - inputOffset;
        if (inBlock > remainIn) inBlock = remainIn;

        // 入力ポインタ設定
        for (int ch = 0; ch < channels; ++ch) {
            if (inBlock > 0 && inputOffset < inputFrames) {
                inPtrs[ch] = input[ch] + inputOffset;
            } else {
                // 入力が尽きたらゼロを送る
                std::memset(inBufs[ch].data(), 0, blockSize * sizeof(float));
                inPtrs[ch] = inBufs[ch].data();
                inBlock = 0;
            }
            outPtrs[ch] = output[ch] + outputOffset;
        }

        impl->stretcher.process(
            inPtrs.data(), inBlock,
            outPtrs.data(), outBlock
        );

        inputOffset += inBlock;
        outputOffset += outBlock;
    }

    return outputOffset;
}

} // extern "C"
