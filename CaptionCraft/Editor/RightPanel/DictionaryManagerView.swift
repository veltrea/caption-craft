import SwiftUI

// MARK: - DictionaryManagerView

/// 校正辞書のエントリ一覧・追加・編集・削除 UI。
///
/// 成熟度: experimental
struct DictionaryManagerView: View {

    static func intent() -> String {
        """
        役割: CorrectionDictionary の CRUD UI。
              手動登録 / 自動学習エントリの管理。
              ドメインヒントの編集。
        成熟度: experimental
        依存: DictionaryStore, CaptionSettings (domainHints)
        """
    }

    @ObservedObject var dictionaryStore: DictionaryStore
    @ObservedObject var store: ProjectStore
    @State private var showAddSheet: Bool = false
    @State private var newWrong: String = ""
    @State private var newCorrect: String = ""
    @State private var newCaseSensitive: Bool = false
    @State private var newDomainHint: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.Dict.title)

            // ドメインヒント
            domainHintsSection

            Divider().background(Color.white.opacity(0.1))

            // エントリ一覧
            entriesSection

            // 追加ボタン
            addEntrySection
        }
    }

    // MARK: - Domain hints

    private var domainHintsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(L10n.Dict.domainHint)

            let hints = store.project?.editor.captionSettings.domainHints ?? []
            FlowLayout(spacing: 4) {
                ForEach(hints, id: \.self) { hint in
                    HStack(spacing: 2) {
                        Text(hint)
                            .font(.system(size: 10))
                        Button {
                            removeDomainHint(hint)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.cyan.opacity(0.2))
                    )
                }
            }

            HStack(spacing: 4) {
                TextField("例: AI, プログラミング", text: $newDomainHint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .frame(width: 140)
                    .onSubmit { addDomainHint() }

                Button {
                    addDomainHint()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(newDomainHint.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Entries

    @ViewBuilder
    private var entriesSection: some View {
        let entries = dictionaryStore.dictionary.entries
            .sorted { $0.useCount > $1.useCount }

        if entries.isEmpty {
            Text(L10n.Dict.empty)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }
            }
            .frame(maxHeight: 200)

            Text(L10n.Dict.entryCount(entries.count))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func entryRow(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("\"\(entry.wrong)\"")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .strikethrough()

                    Text(L10n.Common.arrow)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)

                    Text("\"\(entry.correct)\"")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }

                HStack(spacing: 6) {
                    Text(sourceLabel(entry.source))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)

                    Text(L10n.Dict.useCount(entry.useCount))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if entry.caseSensitive {
                        Text("Aa")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.cyan)
                    }
                }
            }

            Spacer()

            Button {
                dictionaryStore.removeEntry(id: entry.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.02))
        )
    }

    // MARK: - Add entry

    @ViewBuilder
    private var addEntrySection: some View {
        if showAddSheet {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(L10n.Dict.newEntry)

                HStack(spacing: 4) {
                    TextField("誤認識 (例: quad code)", text: $newWrong)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    Text(L10n.Common.arrow)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)

                    TextField("正しい表記 (例: Claude Code)", text: $newCorrect)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                }

                HStack(spacing: 8) {
                    Toggle("大小文字区別", isOn: $newCaseSensitive)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10))
                        .controlSize(.small)

                    Spacer()

                    Button(L10n.Common.cancel) {
                        showAddSheet = false
                        clearNewEntry()
                    }
                    .controlSize(.mini)

                    Button(L10n.Dict.add) {
                        addEntry()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(newWrong.isEmpty || newCorrect.isEmpty)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.2))
            )
        } else {
            Button {
                showAddSheet = true
            } label: {
                Label(L10n.Dict.addEntry, systemImage: "plus.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Actions

    private func addEntry() {
        let entry = DictionaryEntry(
            wrong: newWrong.trimmingCharacters(in: .whitespaces),
            correct: newCorrect.trimmingCharacters(in: .whitespaces),
            caseSensitive: newCaseSensitive,
            source: .manual
        )
        dictionaryStore.addEntry(entry)
        clearNewEntry()
        showAddSheet = false
    }

    private func clearNewEntry() {
        newWrong = ""
        newCorrect = ""
        newCaseSensitive = false
    }

    private func addDomainHint() {
        let hint = newDomainHint.trimmingCharacters(in: .whitespaces)
        guard !hint.isEmpty else { return }
        guard var state = store.project?.editor else { return }
        if !state.captionSettings.domainHints.contains(hint) {
            state.captionSettings.domainHints.append(hint)
            store.commitState(state)
        }
        newDomainHint = ""
    }

    private func removeDomainHint(_ hint: String) {
        guard var state = store.project?.editor else { return }
        state.captionSettings.domainHints.removeAll { $0 == hint }
        store.commitState(state)
    }

    private func sourceLabel(_ source: DictionaryEntrySource) -> String {
        switch source {
        case .autoLearned:  return "自動学習"
        case .manual:       return "手動登録"
        case .llmSuggested: return "LLM提案"
        }
    }

    // MARK: - UI helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(EditorTheme.textPrimary)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(EditorTheme.textSecondary)
    }
}

// MARK: - FlowLayout

/// タグ的な要素を横に並べて折り返すレイアウト。
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            if index < result.positions.count {
                let pos = result.positions[index]
                subview.place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                              proposal: .unspecified)
            }
        }
    }

    private struct ArrangeResult {
        var positions: [CGPoint]
        var size: CGSize
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> ArrangeResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return ArrangeResult(positions: positions, size: CGSize(width: maxWidth, height: totalHeight))
    }
}
