**Read this in other languages:** [日本語](CHANGELOG.ja.md)

# Changelog

All notable changes to CaptionCraft are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/), and versioning follows [Semantic Versioning](https://semver.org/).

---

## [v0.0.1] — 2026-05-27

First public release.

### Features

- **Multi-engine STT**: WhisperKit (CoreML/ANE), Parakeet TDT, Qwen3-ASR, faster-whisper
  - Whisper models available in six sizes from Tiny to Large v3 Turbo
- **VAD (voice activity detection)**: automatic silence skipping, with a no-VAD mode available
- **Ensemble cross-check**: compare the output of multiple STT engines to verify accuracy
- **LLM contextual correction**: rewrite subtitle text with surrounding context using a local LLM
- **Dictionary-based correction**: user-defined rules combined with a learned correction history
- **Translation**: subtitle translation via a local LLM (one segment at a time, with surrounding context, enforced by JSON Schema)
- **YouTube mode**: pull audio from a YouTube URL and generate subtitles in real time
- **Re-listen panel**: 6-band parametric EQ + 10-band graphic EQ, slice markers, variable-speed playback
- **Subtitle format**: SRT read/write
- **Time-stretching**: pitch-preserving variable-speed playback via Signalsmith Stretch
- **ACP (Agent Control Protocol)**: drive the app from external tools over `localhost:9876`
- **Full CJK support**: Japanese / Chinese / Korean IME and language codes designed in from day one

### Environment

- macOS 15.0+
- Apple Silicon (optimized for CoreML / Neural Engine)
- Xcode 16.4 / xcodegen (build time)

[v0.0.1]: https://github.com/veltrea/caption-craft/releases/tag/v0.0.1
