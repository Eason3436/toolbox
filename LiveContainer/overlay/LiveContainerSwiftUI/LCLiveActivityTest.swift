//
//  LCLiveActivityTest.swift
//
//  Added by Eason3436/toolbox: a page (App 更新 → 即時動態) to check that
//  LiveContainer's Live Activity widget works, and to clear leftovers that
//  apps left behind when they were closed.
//

import ActivityKit
import SwiftUI

struct LCLiveActivityTestView: View {
    @State private var enabled = false
    @State private var running: [String] = []
    @State private var message: String?

    var body: some View {
        List {
            Section {
                row("即時動態", enabled ? "已允許" : "未允許")
                row("顯示中", "\(running.count) 個")
            } footer: {
                Text("在 LiveContainer 裡執行的 App，可以用 LiveContainer 的即時動態顯示在鎖定畫面和動態島。App 要使用 LCLiveActivityAttributes（格式見 toolbox repo 的 LiveContainer/README.md）。")
            }

            Section {
                Button("顯示測試即時動態") { start() }
                Button("更新進度") { advance() }
                    .disabled(running.isEmpty)
                Button("顯示完成狀態") { finish() }
                    .disabled(running.isEmpty)
                Button("全部結束", role: .destructive) { endAll() }
                    .disabled(running.isEmpty)
            } footer: {
                if let message {
                    Text(message)
                }
            }

            if !running.isEmpty {
                Section("目前的即時動態") {
                    ForEach(running, id: \.self) { line in
                        Text(line)
                    }
                }
            }
        }
        .navigationTitle("即時動態")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private func refresh() {
        guard #available(iOS 16.2, *) else { return }
        enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        running = Activity<LCLiveActivityAttributes>.activities.map {
            "\($0.attributes.appName)：\($0.content.state.title)"
        }
    }

    private func start() {
        guard #available(iOS 16.2, *) else {
            message = "需要 iOS 16.2 以上"
            return
        }
        let attributes = LCLiveActivityAttributes(
            appName: "LiveContainer",
            bundleName: "",
            systemImage: "shippingbox.fill",
            tintHex: "#0A84FF"
        )
        let state = LCLiveActivityAttributes.ContentState(
            title: "測試中",
            subtitle: "鎖定畫面和動態島都會顯示",
            progress: 0.2,
            timerStart: .now
        )
        do {
            _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            message = "已開始，回到主畫面看看動態島。"
        } catch {
            message = "無法開始：\(error.localizedDescription)"
        }
        refresh()
    }

    private func advance() {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<LCLiveActivityAttributes>.activities {
            var state = activity.content.state
            let next = (state.progress ?? 0) + 0.2
            state.progress = next > 1.0001 ? 0 : next
            state.subtitle = "進度更新於 \(Date.now.formatted(date: .omitted, time: .shortened))"
            state.detail = "第 \(Int((state.progress ?? 0) * 5 + 0.5))/5 個"
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        }
        message = "已更新"
    }

    private func finish() {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<LCLiveActivityAttributes>.activities {
            var state = activity.content.state
            state.title = "完成"
            state.isFinished = true
            state.pausedElapsed = Date.now.timeIntervalSince(state.timerStart ?? .now)
            state.tintHex = "#34C759"
            Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(5 * 60))) }
        }
        message = "已結束，鎖定畫面會留 5 分鐘"
        refresh()
    }

    private func endAll() {
        guard #available(iOS 16.2, *) else { return }
        let activities = Activity<LCLiveActivityAttributes>.activities
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            await MainActor.run {
                message = "已全部結束"
                refresh()
            }
        }
    }
}
