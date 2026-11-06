import SwiftData
import SwiftUI

/// 主介面：賬號/許可權狀態、同步控制、各類資料遊標。
struct DashboardView: View {
    @Environment(HMAppModel.self) private var model
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \SyncState.typeRawValue) private var syncStates: [SyncState]
    @Query(sort: \StressRecord.timestamp, order: .reverse) private var recentStress: [StressRecord]
    @AppStorage("mi_region") private var regionRaw = MiRegion.cn.rawValue
    @State private var showRebackfillConfirm = false
    @State private var showWebLogin = false
    @State private var exportFileURL: URL?

    private var region: MiRegion { .init(rawValue: regionRaw) ?? .cn }

    /// 最近 7 天平均壓力值。
    private var avgStress7d: Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recent = recentStress.filter { $0.timestamp >= cutoff }
        guard !recent.isEmpty else { return nil }
        return Double(recent.map(\.stressScore).reduce(0, +)) / Double(recent.count)
    }

    /// “全部”顯示為中文，其餘顯示“N 天”。
    private var backfillDaysLabel: String {
        model.backfillDays == 3650 ? "全部" : "\(model.backfillDays) 天"
    }

    @Environment(\.dismiss) private var closeHost
    @State private var healthHint: String?

    /// 系統只會跳一次授權畫面；之後要到「健康」App 裡開。失敗時把原因顯示出來。
    private func askHealth() async {
        do {
            try await model.requestHealthKit()
            if !model.healthKitAuthorized {
                healthHint = "系統沒有跳出授權畫面，代表之前已經問過。請打開「健康」App → 右上角頭像 → App → Recap，把要寫入的項目打開。"
            } else {
                healthHint = nil
            }
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("entitlement") {
                healthHint = "這個安裝版本沒有 Apple 健康權限（\(message)）。通常是安裝工具重新簽名時把權限拿掉了。"
            } else {
                healthHint = "授權失敗：\(message)"
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section("賬號") {
                    LabeledContent("小米賬號", value: model.accountID)
                    LabeledContent("連線狀態", value: model.connected ? "已連線" : "未連線")
                    Picker("區域", selection: $regionRaw) {
                        ForEach(MiRegion.allCases) { region in
                            Text(region.displayName).tag(region.rawValue)
                        }
                    }
                    LabeledContent("Apple 健康", value: model.healthKitAuthorized ? "已授權" : "未授權")
                    if !model.healthKitAuthorized {
                        Button("允許寫入 Apple 健康") {
                            Task { await askHealth() }
                        }
                        if let healthHint {
                            Text(healthHint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Link("打開「健康」App", destination: URL(string: "x-apple-health://")!)
                                .font(.footnote)
                        }
                    }
                    if model.authNeedsRefresh {
                        Label("小米憑據已過期，請更新後重試", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button("更新小米憑據") {
                        showWebLogin = true
                    }
                    .sheet(isPresented: $showWebLogin) {
                        MiWebLoginView()
                    }
                }

                // ---------- 增量同步（日常） ----------
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("增量同步", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                        Text("只同步上次之後的新資料，快、省流量。\n日常每天點一次這裡即可。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            Task { await model.syncAll(modelContext: modelContext) }
                        } label: {
                            HStack(spacing: 8) {
                                if model.isSyncing {
                                    ProgressView()
                                    if let progress = model.syncProgressText {
                                        Text(progress).font(.caption)
                                    }
                                }
                                Text(model.isSyncing ? "同步中…" : "立即增量同步")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSyncing)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("同步")
                } footer: {
                    if !model.statusMessage.isEmpty {
                        Text(model.statusMessage)
                    }
                    if let lastError = model.lastError {
                        Text(lastError)
                            .foregroundStyle(.red)
                    }
                }

                // ---------- 重新回填歷史 ----------
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("重新回填歷史", systemImage: "clock.arrow.circlepath")
                            .font(.headline)
                        Text("忽略增量遊標，按所選範圍全量重拉並重寫。\n用於補歷史或修正資料，不會產生重複。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("回填範圍", selection: $model.backfillDays) {
                            Text("7 天").tag(7)
                            Text("30 天").tag(30)
                            Text("90 天").tag(90)
                            Text("全部（3650 天）").tag(3650)
                        }
                        .pickerStyle(.menu)

                        Button("重新回填 \(backfillDaysLabel)") {
                            showRebackfillConfirm = true
                        }
                        .disabled(model.isSyncing)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("重新回填")
                }
                .confirmationDialog(
                    "重新回填 \(backfillDaysLabel)？",
                    isPresented: $showRebackfillConfirm,
                    titleVisibility: .visible
                ) {
                    Button("回填 \(backfillDaysLabel)", role: .destructive) {
                        Task { await model.syncAll(modelContext: modelContext, forceBackfill: true) }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("將從最早 \(backfillDaysLabel) 重新拉取並重寫。由於按 externalID 去重，已存在的資料不會重複。")
                }

                // ---------- 資料概覽 ----------
                Section {
                    summaryRow("步數", value: model.summary?.stepCount.map { "\(Int($0)) 步" })
                    summaryRow("睡眠", value: model.summary?.sleepMinutes.map { String(format: "%.1f 小時", $0 / 60) })
                    summaryRow("平均心率", value: model.summary?.avgHeartRate.map { String(format: "%.0f 次/分", $0) })
                    summaryRow("平均呼吸頻率", value: model.summary?.avgRespiratoryRate.map { String(format: "%.0f 次/分", $0) })
                    summaryRow("平均 HRV", value: model.summary?.avgHRV.map { String(format: "%.0f ms", $0) })
                    summaryRow("平均壓力", value: avgStress7d.map { String(format: "%.0f", $0) })
                } header: {
                    Text("資料概覽（最近 7 天）")
                } footer: {
                    Text("從 Apple 健康讀回，需已授權相應資料型別。")
                }

                // ---------- 資料匯出 ----------
                Section {
                    Button {
                        let csv = DataExporter.exportCSV(days: 7, trends: model.trends, stressRecords: recentStress)
                        exportFileURL = DataExporter.writeCSV(csv)
                    } label: {
                        Label("匯出最近 7 天資料（CSV）", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.trends.isEmpty)
                } header: {
                    Text("資料匯出")
                }

                // ---------- 趨勢圖 ----------
                Section {
                    if model.trends.isEmpty {
                        Text("暫無趨勢資料")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TrendChartsSection()
                        ForEach(model.trends.reversed(), id: \.date) { trend in
                            NavigationLink {
                                HMDayDetailView(trend: trend, stressRecords: recentStress)
                            } label: {
                                daySummaryRow(trend)
                            }
                        }
                    }
                } header: {
                    Text("趨勢（最近 7 天）")
                }

                // ---------- 同步類別 ----------
                Section {
                    ForEach(SyncDataType.allCases) { type in
                        Toggle(type.displayName, isOn: Binding(
                            get: { model.isTypeEnabled(type) },
                            set: { model.setTypeEnabled(type, enabled: $0) }
                        ))
                    }
                } header: {
                    Text("同步類別")
                } footer: {
                    Text("每個類別獨立記錄同步進度，關閉的類別不會同步，也不會更新進度。")
                }

                // ---------- 各類資料狀態 ----------
                Section {
                    ForEach(SyncDataType.allCases) { type in
                        statusRow(type)
                    }
                } header: {
                    Text("各類資料狀態")
                } footer: {
                    Text("「上次同步」就是該類的增量進度；下次增量從它往前 1 天開始拉取。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("用「捷徑」寫入 Apple 健康").font(.headline)
                        Text("免費開發者帳號拿不到健康權限，上面的同步按鈕會失敗。改用捷徑：")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("""
                        1. 在「捷徑」新增捷徑，加入 Recap 的「取得小米健康資料」，選一種資料類型（例如步數）。
                        2. 加入「重複每一項目」。
                        3. 在重複裡加入「記錄健康樣本」，選同一種類型；「值」選「重複項目」的「數值」，「日期」選「開始時間」，「結束日期」選「結束時間」。
                        4. 其他資料類型照著再做一組。睡眠要選「睡眠階段」，每個階段各做一組。
                        5. 到「自動化」設定每天早上自動執行，就會每天補上新資料。
                        """)
                        .font(.footnote)
                        Text("預設只給上次之後的新資料，不會重複寫入。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Link(destination: URL(string: "shortcuts://")!) {
                        Label("打開「捷徑」App", systemImage: "square.2.layers.3d")
                    }
                    Button("重設捷徑進度（重新給全部資料）") {
                        MiShortcutExport.resetCursors()
                    }
                }

                Section {
                    Button("退出登入並清除小米憑據", role: .destructive) {
                        model.disconnect(modelContext: modelContext)
                    }
                }
            }
            .navigationTitle("小米健康同步")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { closeHost() }
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SyncHistoryView()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("同步紀錄")
                }
            }
            .task {
                await model.refreshSummary()
                // App Intent 觸發時自動開始同步
                if SyncIntentTrigger.shouldSync {
                    SyncIntentTrigger.shouldSync = false
                    await model.syncAll(modelContext: modelContext)
                }
            }
            .refreshable { await model.syncAll(modelContext: modelContext) }
            .sheet(isPresented: Binding(
                get: { exportFileURL != nil },
                set: { if !$0 { exportFileURL = nil } }
            )) {
                if let exportFileURL {
                    HMShareSheet(items: [exportFileURL])
                }
            }
        }
    }

    private func summaryRow(_ title: String, value: String?) -> some View {
        LabeledContent(title) {
            if let value {
                Text(value)
                    .foregroundStyle(.primary)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func daySummaryRow(_ trend: DailyTrend) -> some View {
        HStack {
            Text(trend.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(trend.stepCount.map { "\(Int($0)) 步" } ?? "—")
                .font(.caption)
        }
    }

    private func statusRow(_ type: SyncDataType) -> some View {
        let enabled = model.isTypeEnabled(type)
        let state = syncStates.first { $0.typeRawValue == type.rawValue }
        let outcome = model.outcomes[type]
        return LabeledContent(type.displayName) {
            if !enabled {
                Text("已關閉")
                    .foregroundStyle(.tertiary)
            } else if let state, let last = state.lastSyncAt {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("上次 \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let outcome {
                        Text("新增 \(outcome.added) · 拉取 \(outcome.fetched)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("未同步")
                    .foregroundStyle(.secondary)
            }
        }
    }
}


/// UIActivityViewController 的 SwiftUI 包裝。
struct HMShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
