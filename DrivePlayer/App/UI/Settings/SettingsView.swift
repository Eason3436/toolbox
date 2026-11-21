import SwiftUI

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(AppServices.Keys.autoPlayNext) private var autoPlayNext = true
    @AppStorage(AppServices.Keys.askBeforeResume) private var askBeforeResume = false
    @State private var signingIn = false
    @State private var error: String?

    private var auth: GoogleAuthService { services.auth }

    var body: some View {
        List {
            Section("Google 帳號") {
                switch auth.state {
                case .restoring:
                    HStack {
                        ProgressView()
                        Text("正在恢復登入…").foregroundStyle(.secondary)
                    }
                case .signedOut:
                    if auth.isConfigured {
                        Button {
                            Task { await signIn() }
                        } label: {
                            Label("登入 Google", systemImage: "person.crop.circle.badge.plus")
                        }
                        .disabled(signingIn)
                    } else {
                        Label(AuthError.notConfigured.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                case .signedIn:
                    VStack(alignment: .leading, spacing: 2) {
                        Text(auth.displayName ?? "已登入")
                        if let email = auth.email {
                            Text(email).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !auth.hasDriveScope {
                        Label(AuthError.missingScope.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                        Button("重新登入並允許") { Task { await signIn() } }
                    }
                    Button("登出", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            if auth.state == .signedIn {
                Section("雲端硬碟") {
                    NavigationLink(value: DriveFolderRef.root) {
                        Label("我的雲端硬碟", systemImage: "externaldrive.fill")
                    }
                    NavigationLink(value: DriveFolderRef.sharedWithMe) {
                        Label("與我共用", systemImage: "person.2.fill")
                    }
                }
            }

            Section {
                Toggle("自動播放下一集", isOn: $autoPlayNext)
                Toggle("續播時先詢問", isOn: $askBeforeResume)
            } header: {
                Text("播放")
            } footer: {
                Text("自動播放下一集：一集播完後倒數 10 秒播下一集。續播時先詢問：有進度時讓你選擇繼續或從頭播放。")
            }

            Section("關於") {
                LabeledContent("版本", value: AppConfig.version)
                LabeledContent("TMDB", value: AppConfig.tmdbAPIKey == nil ? "尚未設定 API Key" : "已設定")
            }
        }
        .navigationTitle("設定")
        .navigationDestination(for: DriveFolderRef.self) { folder in
            DriveBrowserView(folder: folder)
        }
    }

    private func signIn() async {
        signingIn = true
        defer { signingIn = false }
        do {
            try await auth.signIn()
            error = nil
        } catch AuthError.cancelled {
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
