import SwiftUI

/// 首次使用：輸入小米憑據 → 驗證連線 → 請求 HealthKit 授權。
struct OnboardingView: View {
    @Environment(HMAppModel.self) private var model

    @State private var userId = ""
    @State private var passToken = ""
    @State private var showToken = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showWebLogin = false

    @Environment(\.dismiss) private var closeHost

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("HealthMi")
                            .font(.largeTitle.bold())
                        Text("把小米運動健康（Mi Fitness）雲端的步數、心率、睡眠、血氧、體重等資料，寫入 Apple 健康。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !HealthKitManager.isAvailable {
                        Label("當前裝置不支援 HealthKit", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }

                    Button {
                        showWebLogin = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "globe.asia.australia")
                            Text("使用小米賬號網頁登入")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("在小米官方頁面完成登入（支援驗證碼、簡訊驗證），登入成功後自動儲存憑據。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DisclosureGroup("手動貼上 Cookie（高階）") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("小米賬號")
                                .font(.headline)
                            TextField("userId（account.xiaomi.com 的 Cookie）", text: $userId)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))

                            // 用普通 TextField 而非 SecureField：安全輸入框在 iOS 上強制系統鍵盤，
                            // 第三方鍵盤（含從 Mac 複製貼上）無法使用。
                            HStack(spacing: 8) {
                                Group {
                                    if showToken {
                                        TextField("passToken（有效期短，過期需重新獲取）", text: $passToken)
                                    } else {
                                        SecureField("passToken", text: $passToken)
                                    }
                                }
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                Button {
                                    showToken.toggle()
                                } label: {
                                    Image(systemName: showToken ? "eye.slash" : "eye")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))

                            Text("passToken 預設明文顯示以相容第三方鍵盤貼上，可點選眼睛隱藏。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }

                            Button {
                                Task { await onSubmit() }
                            } label: {
                                Group {
                                    if isWorking {
                                        ProgressView().tint(.white)
                                    } else {
                                        Text("儲存並連線")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(userId.isEmpty || passToken.isEmpty || isWorking)
                        }
                        .padding(.top, 8)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

                    Text("憑據僅儲存在本機鑰匙串（Keychain），用於從你賬號雲端讀取資料。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("小米健康同步")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { closeHost() }
                }
            }
            .sheet(isPresented: $showWebLogin) {
                MiWebLoginView(onConnected: {
                    try? await model.requestHealthKit()
                })
            }
        }
    }

    private func onSubmit() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await model.saveCredentials(userId: userId.trimmingCharacters(in: .whitespaces),
                                            passToken: passToken.trimmingCharacters(in: .whitespaces))
            try await model.requestHealthKit()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

