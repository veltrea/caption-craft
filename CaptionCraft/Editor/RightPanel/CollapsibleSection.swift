import SwiftUI

struct CollapsibleSection<Content: View>: View {
    let title: String
    let icon: String?
    /// e2eTrack 用 ID サフィックス (例: "videoEffects" → "editor.rightPanel.section.videoEffects.toggle")。
    /// 呼び出し側から渡す。nil のときは toggle ボタンに e2eTrack を付けない。
    let idSuffix: String?
    @State private var isExpanded: Bool = true
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        icon: String? = nil,
        idSuffix: String? = nil,
        initiallyExpanded: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.idSuffix = idSuffix
        self._isExpanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            toggleButton

            if isExpanded {
                content()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }

            Divider()
        }
    }

    @ViewBuilder
    private var toggleButton: some View {
        let button = Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if let idSuffix {
            button.e2eTrack(
                id: "editor.rightPanel.section.\(idSuffix).toggle",
                role: "AXButton",
                label: title
            )
        } else {
            button
        }
    }
}
