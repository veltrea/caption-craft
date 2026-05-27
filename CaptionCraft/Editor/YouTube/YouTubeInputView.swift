import SwiftUI

/// YouTube URL を入力するビュー。プレビューエリアの空状態またはシートとして表示する。
struct YouTubeInputView: View {

    static func intent() -> String {
        """
        役割: YouTube URL のテキスト入力 + バリデーション + 読み込み開始。
        EditorTheme 準拠のダーク UI。

        成熟度: experimental
        """
    }

    @Binding var urlText: String
    var onLoad: (String) -> Void

    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("YouTube URL を入力")
                .font(.headline)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                TextField("https://www.youtube.com/watch?v=...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 400)
                    .onSubmit { validate() }

                Button("読み込む") { validate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("対応形式: youtube.com/watch?v=, youtu.be/, shorts/")
                .font(.caption)
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
    }

    private func validate() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if YouTubeURLValidator.extractVideoID(trimmed) != nil {
            validationError = nil
            onLoad(trimmed)
        } else {
            validationError = "有効な YouTube URL ではありません"
        }
    }
}
