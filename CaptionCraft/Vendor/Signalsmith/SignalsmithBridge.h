#ifndef SIGNALSMITH_BRIDGE_H
#define SIGNALSMITH_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void* SSStretcher;

/// Signalsmith Stretch インスタンスを生成する。
/// presetDefault で初期化される (高品質プリセット)。
SSStretcher ss_create(int sampleRate, int channels);

/// インスタンスを破棄する。
void ss_destroy(SSStretcher s);

/// オフラインタイムストレッチを実行する。
/// - input: non-interleaved サンプル配列 [ch0_ptr, ch1_ptr, ...]
/// - inputFrames: 入力フレーム数
/// - output: 呼び出し側が確保した non-interleaved 出力バッファ [ch0_ptr, ch1_ptr, ...]
/// - outputFrames: 出力フレーム数 (= inputFrames * timeRatio が目安)
/// - timeRatio: 伸縮率。2.0 = 2倍に伸ばす (半分の速度)、0.5 = 半分に縮める (2倍速)
/// - channels: チャンネル数
/// - 戻り値: 実際に書き込んだ出力フレーム数
int ss_stretch_offline(
    SSStretcher s,
    const float* const* input,
    int inputFrames,
    float** output,
    int outputFrames,
    double timeRatio,
    int channels
);

#ifdef __cplusplus
}
#endif

#endif
