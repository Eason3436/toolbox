import SwiftUI

/// TMDB API Key：在 App 裡輸入、檢查後存進鑰匙圈。不編進 IPA，公開的 Release 裡看不到。
struct TMDBKeySection: View {
    @Environment(AppServices.self) private var services
    @State private var input = ""
    @State private var editing = false
    @State private var checking = false
    @State private var message: String?
    @State private var saved = false

    private var hasKey: Bool { services.matcher.isConfigured }

    var body: some View {
        Section {
            if hasKey && !editing {
                LabeledContent("API Key", value: "已設定")
                Button("更換 API Key") {
                    input = ""
                    message = nil
                    editing = true
                }
                Button("移除 API Key", role: .destructive) {
                    AppConfig.tmdbAPIKey = nil
                    services.matcher.useClient(nil)
                }
            } else {
                SecureField("貼上 API Key 或 Read Access Token", text: $input)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text("檢查並儲存")
                        if checking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                if editing {
                    Button("取消") {
                        editing = false
                        message = nil
                    }
                }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("TMDB")
        } footer: {
            Text("海報、簡介、演員資料來自 TMDB。到 themoviedb.org 的帳號設定 → API 申請，v3 的 API Key 或 Read Access Token 都可以。Key 只存在這支 iPhone 的鑰匙圈，不會放進 App 安裝檔。")
        }
        .appFeedback(.success, trigger: saved)
    }

    private func save() async {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let client = TMDBClient(apiKey: key) else { return }
        checking = true
        defer { checking = false }
        do {
            try await client.validate()
            AppConfig.tmdbAPIKey = key
            services.matcher.useClient(client)
            input = ""
            message = nil
            editing = false
            saved.toggle()
        } catch TMDBError.unauthorized {
            message = "這個 API Key 無效，請確認有沒有複製完整"
        } catch {
            message = "無法確認：\(error.localizedDescription)"
        }
    }
}
