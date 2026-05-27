import SwiftUI

/// 設定画面の本体。
///
/// CaptionCraft で実装済みの設定のみ表示する。
/// 未実装のプレースホルダ項目は置かない。
struct EditingPreferencesPane: View {

    @ObservedObject var store: PreferencesStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PreferenceRow(
                    title: "主 STT エンジン",
                    description: store.sttEngine.summary
                ) {
                    Picker("", selection: $store.sttEngine) {
                        ForEach(STTEngineType.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }

                if store.sttEngine == .whisper {
                    Divider().padding(.vertical, 8)

                    PreferenceRow(
                        title: "Whisper モデル",
                        description: store.whisperModelVariant.summary
                    ) {
                        Picker("", selection: $store.whisperModelVariant) {
                            ForEach(WhisperModelVariant.allCases) { variant in
                                Text(variant.displayName).tag(variant)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }
                }

                Divider().padding(.vertical, 8)

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        store.resetAll()
                    } label: {
                        Text(L10n.Prefs.General.reset)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    Spacer()
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }
}

#Preview {
    EditingPreferencesPane(store: PreferencesStore.shared)
        .frame(width: 620, height: 480)
}
