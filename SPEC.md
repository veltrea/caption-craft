**Read this in other languages:** [日本語](SPEC.ja.md)

# CaptionCraft Specification

This document captures CaptionCraft's feature scope and behavior. Implementation details live in the linked documents.

- Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Data models: [docs/DATA_MODELS.md](docs/DATA_MODELS.md)
- UI design system: [docs/DESIGN.md](docs/DESIGN.md)

---

## 1. Product goals

A Mac-native application specialized in **generating, editing, and saving subtitles**. Primary users: deaf/HoH users, subtitle translators, and content creators.

### In scope
- Subtitle generation from video/audio (STT)
- Subtitle correction and translation
- Subtitle timeline editing
- SRT read/write
- Variable-speed playback with EQ for re-listening

### Out of scope
- Video recording
- Video editing (cuts, transitions, effects)
- GIF / thumbnail generation
- Cloud uploads

---

## 2. Supported environment

| Item | Requirement |
|---|---|
| OS | macOS 15.0+ |
| CPU | Apple Silicon (M1 or newer) |
| Memory | 16 GB recommended (8 GB works, but the larger Whisper models will struggle) |
| Storage | 1–10 GB for the app and the selected models |
| Network | Only used for the initial model download; fully offline afterward |

Intel Macs are not supported — optimizations assume CoreML / Neural Engine.

---

## 3. STT (audio → subtitles)

### 3.1 Available engines

| Engine | Strengths | How it's bundled |
|---|---|---|
| WhisperKit | General-purpose, 99 languages, CoreML + ANE | SPM |
| Parakeet TDT | High accuracy on 25 European languages, low latency | SPM (SpeechSwift) |
| Qwen3-ASR | Qwen3-based, multilingual | SPM (SpeechSwift) |
| faster-whisper | CPU/GPU, specialized or server-backed use cases | Python subprocess |

The user picks an engine from the right panel based on language and workload. CaptionCraft never collapses STT down to a single engine.

### 3.2 Whisper model sizes

Six tiers: Tiny / Base / Small / Medium / Large v3 / Large v3 Turbo. `CaptionModelManager` handles download and management.

### 3.3 VAD (voice activity detection)

- **Default**: SpeechVAD skips silences and only feeds speech regions to STT
- **No-VAD mode**: streams the full audio to STT, intended for short or densely-packed audio

### 3.4 Ensemble cross-check

Run multiple STT engines over the same region and show the differences. `EnsembleCheckSession` executes them sequentially on demand — parallel execution is intentionally avoided because of ANE/GPU contention.

---

## 4. LLM contextual correction / translation

A local LLM (LM Studio, Ollama, etc.) is called via the **OpenAI Chat Completions compatible API**. No cloud APIs are used.

### 4.1 Contextual correction

- **Target**: the full subtitle track or a selected range
- **Flow**: `CorrectionService` sends the segment together with surrounding context to the LLM, then records the result in a `CorrectionRecord` history
- **Dictionary correction**: `DictionaryCorrector` performs deterministic batch replacements as a pure function (usable before or after LLM correction)

### 4.2 Translation

- **One segment at a time** with surrounding context
- **JSON Schema** enforces the response shape
- Batch translation and context-free translation are intentionally not supported, to avoid accuracy degradation

### 4.3 LLM endpoint

Defaults to `http://localhost:1234`. Configurable from the Preferences window.

---

## 5. Subtitle model

`CaptionRegion` represents a single segment:

- Start / end time (seconds)
- Text
- Confidence (from STT)
- Language code (BCP 47)
- Link to correction history

See [DATA_MODELS.md](docs/DATA_MODELS.md) for the full definition.

---

## 6. File I/O

### 6.1 Input

| Kind | Format |
|---|---|
| Local video | Anything AVFoundation can decode (mp4 / mov / mkv, etc.) |
| Local audio | wav / mp3 / m4a / flac, etc. |
| Project file | `.captioncraft` (current), `.screencraft` / `.openscreen` (legacy) |
| YouTube URL | Playback through WKWebView + yt-dlp download or ScreenCaptureKit capture |

### 6.2 Output

| Kind | Format |
|---|---|
| Project save | `.captioncraft` (directory package, JSON inside) |
| Subtitle export | SRT |
| Planned | VTT / ASS |

---

## 7. Re-listen panel

A playback aid for reviewing and revising newly generated subtitles.

- **EQ**: 6-band parametric EQ + 10-band graphic EQ (Biquad IIR)
- **Slicing**: jump-to points at subtitle boundaries or silence
- **Variable speed**: pitch-preserving 0.5x–2.0x playback via Signalsmith Stretch
- **Looping**: repeat playback of an arbitrary range

---

## 8. ACP (Agent Control Protocol)

A local HTTP server (`localhost:9876`, NWListener-backed) lets external tools (e.g. Claude Code) drive the app.

Key endpoints:

| Method | Path | Purpose |
|---|---|---|
| GET | `/status` | Application status |
| POST | `/transcribe` | Start subtitle generation |
| POST | `/correct` | Run LLM correction |
| POST | `/translate` | Run translation |
| POST | `/export-srt` | Export SRT |
| POST | `/save` | Save project |

The full endpoint list is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## 9. Internationalization

- **UI languages**: Japanese / English (Resources/ja.lproj, en.lproj)
- **CJK as a first-class citizen**: subtitle language codes, IME support, and vertical writing are part of the original design
- **STT languages**: depends on the selected engine (Whisper covers 99 languages, Parakeet covers 25 European languages, etc.)

---

## 10. Distribution

- **License**: MIT
- **Distribution**: self-signed ad-hoc builds (Developer ID + notarization under consideration)
- **Public repo**: [github.com/veltrea/caption-craft](https://github.com/veltrea/caption-craft) (snapshots)
- **Internal development log**: DEVLOG.md (not published)
