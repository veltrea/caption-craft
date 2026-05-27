**Read this in other languages:** [日本語](README.ja.md)

# CaptionCraft

**A native Mac AI subtitle editor**, purpose-built for deaf and hard-of-hearing users, subtitle translators, and content creators.

Speech recognition, contextual correction, and translation all run on-device. No audio leaves your machine.

---

## Features

- **Multi-engine STT**: Choose between WhisperKit (CoreML/ANE), Parakeet TDT, Qwen3-ASR, and faster-whisper depending on language and use case
- **Voice Activity Detection**: Automatic silence skipping via SpeechVAD, with a no-VAD mode also available
- **Ensemble cross-check**: Compare the output of multiple STT engines to gauge recognition accuracy
- **LLM contextual correction**: A local LLM rewrites subtitle text using surrounding context
- **Dictionary-based correction**: User-defined replacement rules combined with a learned correction history
- **Translation**: Subtitle translation via a local LLM
- **YouTube mode**: Pull audio from a YouTube URL and generate subtitles in real time
- **Re-listen panel**: 6-band parametric EQ + 10-band graphic EQ, slice markers, variable-speed playback
- **Subtitle formats**: Read/write SRT (VTT/ASS planned)
- **CJK as a first-class citizen**: Correct language codes and full IME support designed in from day one

## Tech stack

| Purpose | Framework |
|---|---|
| STT (Whisper) | [WhisperKit](https://github.com/argmaxinc/WhisperKit) — CoreML + Neural Engine |
| STT (Parakeet/Qwen3) | [SpeechSwift](https://github.com/soniqo/speech-swift) — native CoreML |
| STT (faster-whisper) | Python subprocess (CPU/GPU, broad language coverage) |
| VAD | SpeechVAD (bundled with SpeechSwift) |
| Audio time-stretching | [Signalsmith Stretch](https://signalsmith-audio.co.uk/code/stretch/) (C++, vendored) |
| Audio EQ | Biquad IIR filters (MTAudioProcessingTap) |
| Subtitle rendering | SwiftUI / AppKit |
| Video playback | AVFoundation (AVPlayer) |
| LLM correction / translation | Local LLM client (LLMClient) |
| Data | Swift Codable / JSON |

## Build

```bash
# First time only: create a self-signed cert
scripts/setup_dev_cert.sh

# Build and launch
scripts/run.sh

# Restart / stop / status
scripts/run.sh restart
scripts/run.sh stop
scripts/run.sh status
```

Requirements: macOS 15.0+ / Xcode 16.4 / [xcodegen](https://github.com/yonaskolb/XcodeGen) / Apple Silicon

## Source layout

```
CaptionCraft/
├── App/                  # App entry point, AppDelegate
├── Editor/
│   ├── Caption/          # STT engines, VAD, LLM correction, dictionary, ensemble
│   ├── ListenPanel/      # Re-listen panel (EQ, waveform, slices)
│   ├── Playback/         # Playback control, time-stretching
│   ├── PreviewArea/      # Video preview + subtitle overlay
│   ├── RightPanel/       # Subtitle list, correction history, translation panel
│   ├── Timeline/         # Timeline + waveform display
│   └── YouTube/          # YouTube mode (audio capture, WebView)
├── Localization/         # L10n, prompt management
├── Models/               # CaptionRegion, Project, ProjectStore
├── Preferences/          # Settings UI
├── Shared/               # DesignTokens, AppLog, utilities
├── Vendor/Signalsmith/   # C++ time-stretching library
└── Debug/                # RemoteControlServer (E2E / debug)
scripts/
├── run.sh                # One-shot build + launch
├── setup_dev_cert.sh     # Self-signed certificate setup
├── build.sh              # xcodebuild wrapper
└── stt/                  # Python STT bridge + setup
docs/                     # Design documents
```

## Documentation

| File | Contents |
|---|---|
| [SPEC.md](SPEC.md) | Feature specification |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Overall architecture |
| [DESIGN.md](docs/DESIGN.md) | UI design system ("The Obsidian Lens") |
| [DATA_MODELS.md](docs/DATA_MODELS.md) | Data model design |
| [CHANGELOG.md](CHANGELOG.md) | Release history |
| [THIRD_PARTY_LICENSES.md](docs/THIRD_PARTY_LICENSES.md) | Third-party licenses |

## Design principles

- **Mac-only, native quality**: no cross-platform port planned
- **Fully offline**: local STT + local LLM, no cloud uploads
- **CJK as a first-class citizen**: correct language codes and IME support designed in from day one
- **Accessibility-first**: features for deaf/HoH users built in from the start, not bolted on
- **Multi-engine**: STT is never reduced to a single engine — pick the right one for your language and workload

## License

[MIT](LICENSE)
