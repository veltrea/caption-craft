import SwiftUI

// MARK: - CorrectionHistoryView

/// 選択中 region の校正履歴、または全 region の校正一覧を表示する。
///
/// 成熟度: experimental
struct CorrectionHistoryView: View {

    static func intent() -> String {
        """
        役割: 校正の可視化 UI。2 つのモード:
              - regionMode: 選択中 CaptionRegion の校正履歴を表示
              - allMode: 全 region の校正を一覧表示 (フィルタ付き)
        成熟度: experimental
        依存: CaptionRegion, CorrectionRecord, ProjectStore
        """
    }

    @ObservedObject var store: ProjectStore
    @State private var showAll: Bool = false
    @State private var filter: CorrectionSource? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if showAll {
                allCorrectionsList
            } else {
                regionCorrectionsList
            }
        }
    }

    private var regions: [CaptionRegion] {
        store.project?.editor.captionRegions ?? []
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(L10n.Correction.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EditorTheme.textPrimary)

            Spacer()

            Picker("", selection: $showAll) {
                Text(L10n.Correction.filterSelected).tag(false)
                Text(L10n.Correction.filterAll).tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .controlSize(.mini)
        }
    }

    // MARK: - Region corrections (選択中 region)

    @ViewBuilder
    private var regionCorrectionsList: some View {
        let corrected = regions.filter { !$0.corrections.isEmpty }

        if corrected.isEmpty {
            Text(L10n.Correction.empty)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else {
            // 直近で選択されている or 校正がある region を表示
            let regionsWithCorrections = corrected.prefix(20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(regionsWithCorrections)) { region in
                        regionCorrectionRow(region)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private func regionCorrectionRow(_ region: CaptionRegion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // タイムコード
            Text(formatMs(region.startMs))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)

            ForEach(region.corrections) { record in
                correctionRecordRow(record)
            }

            if let raw = region.originalRawText {
                HStack(spacing: 4) {
                    Text(L10n.Correction.original)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(raw)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.03))
        )
    }

    // MARK: - All corrections (全体一覧)

    @ViewBuilder
    private var allCorrectionsList: some View {
        let allRecords = collectAllRecords()
        let filtered = filterRecords(allRecords)

        VStack(alignment: .leading, spacing: 6) {
            // フィルタ
            HStack(spacing: 4) {
                filterButton(label: L10n.Correction.filterBtnAll, source: nil)
                filterButton(label: L10n.Correction.filterBtnDict, source: .dictionary)
                filterButton(label: L10n.Correction.filterBtnLLM, source: .llm)
                filterButton(label: L10n.Correction.filterBtnManual, source: .userEdit)
            }

            if filtered.isEmpty {
                Text(L10n.Correction.empty)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered, id: \.record.id) { item in
                            allCorrectionRow(item)
                        }
                    }
                }
                .frame(maxHeight: 250)

                // 集計
                let dictCount = filtered.filter { $0.record.source == .dictionary }.count
                let llmCount = filtered.filter { $0.record.source == .llm }.count
                let userCount = filtered.filter { $0.record.source == .userEdit }.count
                Text(L10n.Correction.summary(total: filtered.count, dict: dictCount, llm: llmCount, manual: userCount))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func filterButton(label: String, source: CorrectionSource?) -> some View {
        Button {
            filter = source
        } label: {
            Text(label)
                .font(.system(size: 9, weight: filter == source ? .bold : .regular))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(filter == source ? Color.cyan.opacity(0.3) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func allCorrectionRow(_ item: CorrectionItem) -> some View {
        HStack(spacing: 6) {
            Text(formatMs(item.regionStartMs))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            Text(sourceIcon(item.record.source))
                .font(.system(size: 10))

            Text(sourceLabel(item.record.source))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            store.scrollToRegionID = item.regionID
        }
    }

    // MARK: - Helpers

    private func correctionRecordRow(_ record: CorrectionRecord) -> some View {
        HStack(spacing: 4) {
            Text(sourceIcon(record.source))
                .font(.system(size: 10))

            Text(sourceLabel(record.source))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func sourceIcon(_ source: CorrectionSource) -> String {
        switch source {
        case .dictionary: return "📖"
        case .llm:        return "🔧"
        case .userEdit:   return "✎"
        }
    }

    private func sourceLabel(_ source: CorrectionSource) -> String {
        switch source {
        case .dictionary: return "辞書:"
        case .llm:        return "LLM:"
        case .userEdit:   return "手動:"
        }
    }

    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        let m = s / 60
        let sec = s % 60
        return String(format: "%02d:%02d", m, sec)
    }

    private struct CorrectionItem {
        let regionID: UUID
        let regionStartMs: Int
        let record: CorrectionRecord
    }

    private func collectAllRecords() -> [CorrectionItem] {
        var items: [CorrectionItem] = []
        for region in regions {
            for record in region.corrections {
                items.append(CorrectionItem(
                    regionID: region.id,
                    regionStartMs: region.startMs,
                    record: record
                ))
            }
        }
        return items.sorted { $0.regionStartMs < $1.regionStartMs }
    }

    private func filterRecords(_ items: [CorrectionItem]) -> [CorrectionItem] {
        guard let filter else { return items }
        return items.filter { $0.record.source == filter }
    }
}
