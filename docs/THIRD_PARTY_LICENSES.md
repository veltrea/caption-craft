# サードパーティライセンス

CaptionCraft は以下のオープンソースソフトウェアを使用しています。

---

## 音声認識エンジン

### WhisperKit

- **用途**: Apple Silicon 最適化のローカル Whisper 音声認識
- **作者**: Argmax, Inc.
- **リポジトリ**: https://github.com/argmaxinc/WhisperKit
- **ライセンス**: MIT License
- **統合方法**: Swift Package Manager

> MIT License
> Copyright (c) 2024 Argmax, Inc.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.

### SenseVoice (FunASR)

- **用途**: CTC ベースの高速多言語音声認識 (EN/FR/DE/ES/JA/ZH/KO)
- **作者**: Alibaba DAMO Academy
- **リポジトリ**: https://github.com/FunAudioLLM/SenseVoice
- **ライセンス**: MIT License
- **統合方法**: Python サブプロセス (`scripts/stt/sensevoice_bridge.py`)

> MIT License
> Copyright (c) FunAudioLLM
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software.

### faster-whisper

- **用途**: CTranslate2 最適化 Whisper 実装（int8 量子化・CPU 高速推論）
- **作者**: SYSTRAN / Guillaume Klein
- **リポジトリ**: https://github.com/SYSTRAN/faster-whisper
- **ライセンス**: MIT License
- **統合方法**: Python サブプロセス (`scripts/stt/faster_whisper_bridge.py`)

> MIT License
> Copyright (c) 2023 SYSTRAN
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software.

### Vosk

- **用途**: Kaldi ベースの軽量オフライン音声認識 (CTC)
- **作者**: Alpha Cephei Inc.
- **リポジトリ**: https://github.com/alphacep/vosk-api
- **ライセンス**: Apache License 2.0
- **統合方法**: Python サブプロセス (`scripts/stt/vosk_bridge.py`)

> Copyright 2019-2024 Alpha Cephei Inc.
>
> Licensed under the Apache License, Version 2.0 (the "License");
> you may not use this file except in compliance with the License.
> You may obtain a copy of the License at
>
>     http://www.apache.org/licenses/LICENSE-2.0
>
> Unless required by applicable law or agreed to in writing, software
> distributed under the License is distributed on an "AS IS" BASIS,
> WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

### Google Cloud Speech-to-Text

- **用途**: クラウドベースの高精度音声認識
- **統合方法**: Python サブプロセス (`scripts/stt/google_stt_bridge.py`)
- **注記**: Google Cloud のサービスであり、オープンソースライブラリではない。
  利用には Google Cloud のサービス利用規約が適用される。

---

## 音声処理

### Rubber Band Library

- **用途**: 高品質オフラインタイムストレッチ（スロー再生時の音声品質保持）
- **作者**: Particular Programs Ltd. (Breakfast Quay)
- **リポジトリ**: https://github.com/breakfastquay/rubberband
- **ライセンス**: GNU General Public License v2 (デュアルライセンス: GPL v2 / 商用)
- **統合方法**: シングルファイルコンパイル (`RubberBandSingle.cpp`)、R3 (Finer) エンジン使用
- **バージョン**: 4.0.0

> Copyright 2007-2024 Particular Programs Ltd.
>
> This program is free software; you can redistribute it and/or
> modify it under the terms of the GNU General Public License as
> published by the Free Software Foundation; either version 2 of the
> License, or (at your option) any later version.

---

## 推論基盤

### CTranslate2

- **用途**: faster-whisper の推論バックエンド（量子化・最適化）
- **作者**: OpenNMT / SYSTRAN
- **リポジトリ**: https://github.com/OpenNMT/CTranslate2
- **ライセンス**: MIT License

> MIT License
> Copyright (c) 2018 OpenNMT

### FunASR

- **用途**: SenseVoice モデルの推論ランタイム
- **作者**: Alibaba DAMO Academy
- **リポジトリ**: https://github.com/modelscope/FunASR
- **ライセンス**: MIT License

> MIT License
> Copyright (c) Alibaba DAMO Academy

---

## 外部ツール（バンドルなし・ユーザーが別途導入）

以下は CaptionCraft に同梱されておらず、ユーザーが任意で接続する外部ツールです。

- **LM Studio** / **Ollama**: ローカル LLM 推論サーバー（字幕の翻訳・校正に使用）。
  OpenAI Chat Completions 互換 API 経由で接続。
- **ffmpeg**: 音声フォーマット変換（Vosk・Google STT で使用）。
- **Apple Speech** (SFSpeechRecognizer): macOS 標準の音声認識フレームワーク。
  OS 組み込みのため別途ライセンス表記不要。

---
