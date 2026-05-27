import SwiftUI

/// 「CaptionCraft について」ウィンドウのコンテンツ。
///
/// アプリ情報とサードパーティライセンスを表示する。
/// メニューバーの「CaptionCraft → CaptionCraft について」から開く。
struct AboutView: View {

    @State private var selectedTab: Tab = .about

    enum Tab: Hashable {
        case about
        case licenses
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabSelector
            Divider()
            tabContent
        }
        .frame(width: 520, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
            }

            Text(L10n.About.title)
                .font(.system(size: 20, weight: .semibold))

            Text(L10n.About.version(appVersion, buildNumber))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(L10n.About.copyright)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tab selector

    private var tabSelector: some View {
        HStack(spacing: 0) {
            tabButton(L10n.About.tabOverview, tab: .about)
            tabButton(L10n.About.tabLicense, tab: .licenses)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func tabButton(_ title: String, tab: Tab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selectedTab == tab
                              ? Color.accentColor.opacity(0.12)
                              : Color.clear)
                )
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .about:
            aboutContent
        case .licenses:
            licensesContent
        }
    }

    private var aboutContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.About.description)
                    .font(.system(size: 12))

                Text(L10n.About.descriptionDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Licenses

    private var licensesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.About.licenseHeader)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                ForEach(ThirdPartyLicense.all) { entry in
                    licenseCard(entry)
                    if entry.id != ThirdPartyLicense.all.last?.id {
                        Divider()
                    }
                }
            }
            .padding(20)
        }
    }

    private func licenseCard(_ entry: ThirdPartyLicense) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(entry.license)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(licenseColor(entry.license).opacity(0.15))
                    )
                    .foregroundStyle(licenseColor(entry.license))
            }

            Text(entry.purpose)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label(entry.author, systemImage: "person")
                if let link = URL(string: entry.url) {
                    Link(destination: link) {
                        Label(entry.url, systemImage: "link")
                    }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            Text(entry.notice)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }

    private func licenseColor(_ license: String) -> Color {
        switch license {
        case "LGPL-2.1":   return .orange
        case "Apache-2.0": return .green
        case "MIT":         return .blue
        default:            return .secondary
        }
    }

    // MARK: - App info

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}

// MARK: - License data

struct ThirdPartyLicense: Identifiable {
    let id: String
    let name: String
    let author: String
    let url: String
    let license: String
    let purpose: String
    let notice: String

    static let all: [ThirdPartyLicense] = [
        // 音声認識エンジン
        ThirdPartyLicense(
            id: "whisperkit",
            name: "WhisperKit",
            author: "Argmax, Inc.",
            url: "https://github.com/argmaxinc/WhisperKit",
            license: "MIT",
            purpose: "Apple Silicon 最適化のローカル Whisper 音声認識",
            notice: """
            MIT License
            Copyright (c) 2024 Argmax, Inc.

            Permission is hereby granted, free of charge, to any person obtaining \
            a copy of this software and associated documentation files (the \
            "Software"), to deal in the Software without restriction, including \
            without limitation the rights to use, copy, modify, merge, publish, \
            distribute, sublicense, and/or sell copies of the Software, and to \
            permit persons to whom the Software is furnished to do so, subject to \
            the following conditions:

            The above copyright notice and this permission notice shall be included \
            in all copies or substantial portions of the Software.
            """
        ),
        ThirdPartyLicense(
            id: "sensevoice",
            name: "SenseVoice (FunASR)",
            author: "Alibaba DAMO Academy",
            url: "https://github.com/FunAudioLLM/SenseVoice",
            license: "MIT",
            purpose: "CTC ベースの高速多言語音声認識 (EN/FR/DE/ES/JA/ZH/KO)",
            notice: """
            MIT License
            Copyright (c) FunAudioLLM

            Permission is hereby granted, free of charge, to any person obtaining \
            a copy of this software and associated documentation files (the \
            "Software"), to deal in the Software without restriction, including \
            without limitation the rights to use, copy, modify, merge, publish, \
            distribute, sublicense, and/or sell copies of the Software.
            """
        ),
        ThirdPartyLicense(
            id: "faster-whisper",
            name: "faster-whisper",
            author: "SYSTRAN / Guillaume Klein",
            url: "https://github.com/SYSTRAN/faster-whisper",
            license: "MIT",
            purpose: "CTranslate2 最適化 Whisper 実装 (int8 量子化・CPU 高速推論)",
            notice: """
            MIT License
            Copyright (c) 2023 SYSTRAN

            Permission is hereby granted, free of charge, to any person obtaining \
            a copy of this software and associated documentation files (the \
            "Software"), to deal in the Software without restriction, including \
            without limitation the rights to use, copy, modify, merge, publish, \
            distribute, sublicense, and/or sell copies of the Software.
            """
        ),
        ThirdPartyLicense(
            id: "vosk",
            name: "Vosk",
            author: "Alpha Cephei Inc.",
            url: "https://github.com/alphacep/vosk-api",
            license: "Apache-2.0",
            purpose: "Kaldi ベースの軽量オフライン音声認識 (CTC)",
            notice: """
            Copyright 2019-2024 Alpha Cephei Inc.

            Licensed under the Apache License, Version 2.0 (the "License"); \
            you may not use this file except in compliance with the License. \
            You may obtain a copy of the License at

                http://www.apache.org/licenses/LICENSE-2.0

            Unless required by applicable law or agreed to in writing, software \
            distributed under the License is distributed on an "AS IS" BASIS, \
            WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or \
            implied.
            """
        ),
        // 推論基盤
        ThirdPartyLicense(
            id: "ctranslate2",
            name: "CTranslate2",
            author: "OpenNMT / SYSTRAN",
            url: "https://github.com/OpenNMT/CTranslate2",
            license: "MIT",
            purpose: "faster-whisper の推論バックエンド（量子化・最適化）",
            notice: """
            MIT License
            Copyright (c) 2018 OpenNMT

            Permission is hereby granted, free of charge, to any person obtaining \
            a copy of this software and associated documentation files (the \
            "Software"), to deal in the Software without restriction.
            """
        ),
        ThirdPartyLicense(
            id: "funasr",
            name: "FunASR",
            author: "Alibaba DAMO Academy",
            url: "https://github.com/modelscope/FunASR",
            license: "MIT",
            purpose: "SenseVoice モデルの推論ランタイム",
            notice: """
            MIT License
            Copyright (c) Alibaba DAMO Academy

            Permission is hereby granted, free of charge, to any person obtaining \
            a copy of this software and associated documentation files (the \
            "Software"), to deal in the Software without restriction.
            """
        ),
    ]
}

// MARK: - Window controller

final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: AboutView())
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = L10n.App.about
        w.contentView = hostingView
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
