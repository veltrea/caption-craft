import SwiftUI

// MARK: - EnsembleCheckSheet

/// クロスチェックのモーダル UI。
/// ① 現在の字幕（編集可能）と、② ③ 副エンジンの結果を並べて表示。
/// 差分単語を強調表示し、ユーザーが見比べながら正解を組み立てて「更新」で保存する。
struct EnsembleCheckSheet: View {

    @ObservedObject var session: EnsembleCheckSession
    let onDismiss: () -> Void
    let onUpdate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(session.secondaryEngines) { engineType in
                        secondaryBlock(engineType: engineType)
                    }
                    editableBlock
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 620)
        .background(EditorTheme.canvas)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text("クロスチェック")
                    .font(.system(size: 14, weight: .semibold))
                Text(session.timeRangeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Editable block (現在の字幕)

    private var editableBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.cyan)
                Text("現在の字幕")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if session.isTextEdited {
                    Text("(編集済み)")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            TextEditor(text: $session.editedText)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 60, maxHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(session.isTextEdited ? Color.cyan.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
                )
        }
    }

    // MARK: - Secondary block

    private func secondaryBlock(engineType: STTEngineType) -> some View {
        let result = session.results[engineType] ?? EnsembleCheckSession.EngineResult()
        let number = (session.secondaryEngines.firstIndex(of: engineType) ?? 0) + 2

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "\(number).circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(number == 2 ? .orange : .purple)
                Text(engineType.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                phaseChip(result)
            }

            resultContent(result)
        }
    }

    @ViewBuilder
    private func resultContent(_ result: EnsembleCheckSession.EngineResult) -> some View {
        switch result.phase {
        case .waiting:
            Text("待機中…")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.02)))

        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("音声を準備中…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.02)))

        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("認識中…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.02)))

        case .completed(let matched):
            VStack(alignment: .leading, spacing: 4) {
                diffHighlightedText(result.fullText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !matched {
                    Text("類似度 \(Int(result.similarity * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(matched ? Color.green.opacity(0.6) : Color.orange.opacity(0.6), lineWidth: 1)
            )
            .textSelection(.enabled)

        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                Text(result.errorMessage ?? "失敗")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.06)))
        }
    }

    // MARK: - Diff highlighting

    /// 編集中のテキストと副エンジン結果を比較し、差分単語を強調表示する。
    private func diffHighlightedText(_ secondaryText: String) -> Text {
        let words = EnsembleCheckSession.diffWords(
            primary: session.editedText,
            secondary: secondaryText
        )
        guard !words.isEmpty else {
            return Text("(空)").font(.system(size: 14)).foregroundColor(.secondary)
        }

        var result = Text("")
        for (i, word) in words.enumerated() {
            if i > 0 { result = result + Text(" ") }
            if word.isDifferent {
                result = result + Text(word.text)
                    .foregroundColor(.orange)
                    .bold()
            } else {
                result = result + Text(word.text)
            }
        }
        return result.font(.system(size: 14))
    }

    // MARK: - Phase chip

    @ViewBuilder
    private func phaseChip(_ result: EnsembleCheckSession.EngineResult) -> some View {
        switch result.phase {
        case .waiting:
            Text("待機中")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .preparing, .transcribing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(result.phase == .preparing ? "準備中" : "認識中")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        case .completed(let matched):
            HStack(spacing: 4) {
                Image(systemName: matched ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text(matched ? "一致" : "差分あり")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(matched ? .green : .orange)
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 10))
                Text("失敗")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.red)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("閉じる") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)

            Button("更新") {
                onUpdate(session.editedText)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .disabled(!session.isTextEdited)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
