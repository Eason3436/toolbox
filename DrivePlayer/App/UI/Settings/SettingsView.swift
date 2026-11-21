import SwiftUI

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var signingIn = false
    @State private var cacheSize: Int64 = 0
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
                    if auth.sessionExpired {
                        Label(AuthError.expired.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
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

            TMDBKeySection()

            Section("播放器") {
                NavigationLink {
                    PlaybackSettingsView()
                } label: {
                    Label("播放", systemImage: "play.rectangle")
                }
                NavigationLink {
                    SubtitleSettingsView()
                } label: {
                    Label("字幕和音軌", systemImage: "captions.bubble")
                }
            }

            Section {
                Button {
                    services.retryUnmatched()
                } label: {
                    Label("重新比對未辨識的影片", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(services.matcher.isRunning || !services.matcher.isConfigured)
                Button(role: .destructive) {
                    Task {
                        await ImageCache.shared.clear()
                        cacheSize = 0
                    }
                } label: {
                    LabeledContent {
                        Text(cacheSize.formatted(.byteCount(style: .file)))
                    } label: {
                        Label("清除圖片快取", systemImage: "trash")
                    }
                }
                if let error = services.matcher.lastError {
                    Text("TMDB：\(error)").font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("中繼資料與快取")
            } footer: {
                Text("清除快取只會刪掉下載過的海報與背景圖，之後會重新下載；媒體庫與播放進度不受影響。")
            }

            Section("關於") {
                LabeledContent("版本", value: AppConfig.version)
            }
        }
        .navigationTitle("設定")
        .softScrollEdges()
        .task { cacheSize = await ImageCache.shared.diskUsage() }
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
