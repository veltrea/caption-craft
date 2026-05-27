import SwiftUI

/// Settings ウィンドウのルートビュー。
///
/// 実装済みの設定のみ表示する単一ペイン。
/// タブ切替は設定項目が増えた段階で再導入する。
struct PreferencesView: View {

    static func intent() -> String {
        return """
        役割: Settings ウィンドウのコンテナ。

        成熟度: experimental

        変更時の注意:
        - 設定項目が増えてタブが必要になったら TabView を再導入する。
        - 未実装の項目をプレースホルダとして並べない。実装してから追加する。
        """
    }

    @StateObject private var store = PreferencesStore.shared

    var body: some View {
        EditingPreferencesPane(store: store)
            .frame(width: 480, height: 260)
    }
}

// MARK: - 共通パーツ

/// Pane 内で使う「1 行設定項目」の共通コンテナ。
/// 左にタイトル + 説明文、右に任意のコントロールを置く。
struct PreferenceRow<Control: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let control: () -> Control

    init(
        title: String,
        description: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.description = description
        self.control = control
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control()
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    PreferencesView()
}
