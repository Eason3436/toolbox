import SwiftUI

struct SettingsView: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(QueueStatus.self) private var queueStatus
    @Environment(\.openURL) private var openURL
    @AppStorage("importRange") private var importRange: ImportRange = .all
    @State private var confirmReanalyze = false
    @State private var cacheSize = ThumbnailCache.totalSize()

    var body: some View {
        NavigationStack {
            Form {
                Section("截圖") {
                    Picker("匯入範圍", selection: $importRange) {
                        ForEach(ImportRange.allCases) { Text($0.title).tag($0) }
                    }
                    Button("重新同步相簿") { library.resync() }
                    Button("重新分析全部") { confirmReanalyze = true }
                }

                Section {
                    LabeledContent("AI 狀態", value: queueStatus.readiness == .available ? "已就緒" : "未就緒")
                    if queueStatus.readiness != .available {
                        Text(queueStatus.readiness.message).font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("佇列", value: queueStatus.progressText ?? "閒置")
                    LabeledContent("等待分析", value: "\(queueStatus.pendingCount) 張")
                    LabeledContent("分析失敗", value: "\(queueStatus.failedCount) 張")
                    if queueStatus.failedCount > 0 {
                        Button("重試失敗的截圖") {
                            Task { await AppServices.shared.queue.retryFailed() }
                        }
                    }
                } header: {
                    Text("分析佇列")
                } footer: {
                    Text("手機過熱時會暫停；低耗電模式時只在 App 開著時分析；充電時會在背景補分析。")
                }

                Section {
                    LabeledContent("縮圖快取", value: cacheSize.formatted(.byteCount(style: .file)))
                    Button("清除快取", role: .destructive) {
                        ThumbnailCache.clear()
                        cacheSize = ThumbnailCache.totalSize()
                    }
                } footer: {
                    Text("快取只存小縮圖，不會影響相簿裡的原圖。")
                }

                Section {
                    NavigationLink("背面輕點收錄截圖") { ShortcutGuideView() }
                }

                Section {
                    LabeledContent("照片權限", value: accessText)
                    Button("開啟系統設定") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    if AppServices.shared.storageError != nil || !SharedInbox.isAvailable {
                        Text(SharedInbox.isAvailable ? (AppServices.shared.storageError ?? "") : "App Group 無法使用：分享延伸功能送進來的截圖收不到。請確認簽署時有包含 App Group。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("版本", value: version)
                }
            }
            .navigationTitle("設定")
            .onAppear {
                cacheSize = ThumbnailCache.totalSize()
                Task { await AppServices.shared.queue.refreshCounts() }
            }
            .confirmationDialog("重新分析全部截圖？", isPresented: $confirmReanalyze, titleVisibility: .visible) {
                Button("重新分析") { Task { await AppServices.shared.queue.reanalyzeAll() } }
            } message: {
                Text("截圖很多時會花比較久，也比較耗電。")
            }
        }
    }

    private var accessText: String {
        switch library.access {
        case .full: "完整取用"
        case .limited: "部分取用"
        case .denied: "未允許"
        case .notDetermined: "尚未設定"
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（\(build)）"
    }
}

/// 捷徑設定教學。
struct ShortcutGuideView: View {
    private let steps = [
        "打開「捷徑」App，按右上角「＋」新增捷徑。",
        "加入動作「截取螢幕畫面」。",
        "再加入動作「收錄最新截圖」（在 Screenshots 底下），把「截圖」欄位設為上一步的「螢幕截圖」。",
        "把捷徑命名為「收錄截圖」。",
        "打開「設定 → 輔助使用 → 觸控 → 背面輕點」，選「輕點兩下」，再選剛剛的捷徑。",
        "之後在任何畫面輕點手機背面兩下，就會截圖並送進 Screenshots 分析。",
    ]

    var body: some View {
        List {
            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline)
                            .frame(width: 28, height: 28)
                            .glassEffect(in: .circle)
                        Text(step)
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("也可以綁定到動作按鈕：「設定 → 動作按鈕 → 捷徑」。不想多截一張圖的話，第 2 步可以省略，第 3 步的「截圖」欄位留空，就會收錄相簿裡最新的一張截圖。")
            }
        }
        .navigationTitle("背面輕點收錄截圖")
    }
}
