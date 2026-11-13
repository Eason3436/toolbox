import SwiftUI

/// 4K 轉 1080p（保留空間音訊）。
/// 從相簿挑影片 → 顯示原片資訊與自動選定的碼率 → 轉檔 → 存回相簿並驗證空間音訊。
struct DownscaleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var queue = DownscaleQueue()
    @State private var showPicker = false
    @State private var didAutoOpen = false

    var body: some View {
        NavigationStack {
            Form {
                if queue.items.isEmpty {
                    introSection
                }
                if queue.isHot {
                    thermalSection
                }
                ForEach(queue.items) { item in
                    itemSection(item)
                }
                if !queue.items.isEmpty && !queue.isRunning && !queue.hasFinished {
                    Section {
                    } footer: {
                        Text("碼率依解析度、影格率與原片的細節量自動決定，關鍵影格每 2 秒一張。全部在這台裝置上處理。")
                            .foregroundStyle(Color.tbInkSecondary)
                    }
                }
            }
            .tbGroundBackground()
            .listSectionSpacing(24)
            .navigationTitle("4K 轉 1080p")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(isPresented: $showPicker) {
                VideoPicker { results in
                    showPicker = false
                    queue.load(results)
                }
                .ignoresSafeArea()
            }
            .alert("空間音訊寫入失敗",
                   isPresented: Binding(get: { queue.question != nil }, set: { _ in })) {
                Button("只保留立體聲") { queue.resolveQuestion(true) }
                Button("略過這支", role: .cancel) { queue.resolveQuestion(false) }
            } message: {
                if let question = queue.question {
                    Text(question.hasStereo
                         ? "「\(question.itemName)」的空間音訊無法原樣寫入。要改成只保留立體聲繼續轉嗎？"
                         : "「\(question.itemName)」的空間音訊無法原樣寫入，而且這支沒有另外的立體聲軌，繼續的話會沒有聲音。")
                }
            }
        }
        .tint(.tbAccent)
        .interactiveDismissDisabled(queue.isRunning)
        .sensoryFeedback(.success, trigger: queue.successCount)
        .sensoryFeedback(.error, trigger: queue.failureCount)
        .task {
            // 一打開就直接進挑選器，少按一次。
            if !didAutoOpen && queue.items.isEmpty {
                didAutoOpen = true
                // 上次被滑掉、沒按關閉留下的暫存檔，這時候一起清掉。
                DownscaleQueue.removeLeftovers()
                showPicker = true
            }
            // 過熱提示：系統溫度狀態改變時更新。
            for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                let hot = DownscaleSupport.isHot
                withAnimation(.snappy) { queue.isHot = hot }
            }
        }
    }

    // MARK: 說明

    private var introSection: some View {
        Section {
            Label {
                Text("影像重新編碼成 1080p HEVC，碼率依原片自動決定，比直接錄 1080p 更清晰，檔案大約只剩 1/4。")
            } icon: {
                Image(systemName: "rectangle.compress.vertical")
            }
            Label {
                Text("所有音訊軌原封不動複製，空間音訊和立體聲都會保留；HDR、拍攝日期與地點也會保留。")
            } icon: {
                Image(systemName: "spatial.audio.badge.checkmark")
            }
            Label {
                Text("轉好的影片另存到相簿，不會動到原片。")
            } icon: {
                Image(systemName: "photo.on.rectangle")
            }
        }
        .foregroundStyle(Color.tbInk)
        .listRowBackground(Color.tbSurface)
    }

    private var thermalSection: some View {
        Section {
            Label("手機溫度偏高，轉檔會變慢。可以先讓手機休息一下，或拿掉保護殼。",
                  systemImage: "thermometer.high")
                .foregroundStyle(Color.tbWarning)
                .listRowBackground(Color.tbSurface)
        }
    }

    // MARK: 每支影片

    @ViewBuilder
    private func itemSection(_ item: DownscaleQueue.Item) -> some View {
        Section {
            switch item.status {
            case .loading:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("讀取中…").foregroundStyle(Color.tbInkSecondary)
                }
                .listRowBackground(Color.tbSurface)
            case .unsupported(let reason):
                if let probe = item.probe { sourceRows(probe) }
                warningRow(reason, systemImage: "exclamationmark.triangle", color: .tbWarning)
            case .ready:
                if let probe = item.probe {
                    sourceRows(probe)
                    planRows(probe)
                }
            case .running:
                runningRow(item)
            case .done(let outcome):
                doneRows(outcome)
            case .failed(let message):
                warningRow(message, systemImage: "exclamationmark.circle", color: .tbDanger)
            }
        } header: {
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Color.tbInkSecondary)
        }
    }

    /// 原片資訊：解析度、影格率、SDR/HDR、空間音訊。
    @ViewBuilder
    private func sourceRows(_ probe: VideoProbe) -> some View {
        Group {
            LabeledContent("解析度", value: resolutionText(probe))
            LabeledContent("影格率", value: "\(probe.frameRate.formatted(.number.precision(.fractionLength(0...2)))) fps")
            LabeledContent("動態範圍", value: probe.isHDR ? (probe.isPQ ? "HDR（PQ）" : "HDR（HLG）") : "SDR")
            LabeledContent("空間音訊") {
                if probe.hasSpatialAudio {
                    Label("有", systemImage: "spatial.audio.badge.checkmark")
                        .labelStyle(.titleAndIcon)
                } else {
                    Text("沒有")
                }
            }
            if !probe.audioTracks.isEmpty {
                LabeledContent("音軌", value: probe.audioTracks.map(\.label).formatted(.list(type: .and)))
            }
            LabeledContent("長度", value: Duration.seconds(probe.duration)
                .formatted(.time(pattern: probe.duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
        .monospacedDigit()
        .listRowBackground(Color.tbSurface)
    }

    /// 自動選定的碼率與預估大小。
    @ViewBuilder
    private func planRows(_ probe: VideoProbe) -> some View {
        if let plan = probe.plan {
            Group {
                LabeledContent("輸出碼率", value: Self.mbps(plan.targetBitrate))
                LabeledContent("預估大小") {
                    Text("\(Workspace.formattedSize(probe.fileSize)) → 約 \(Workspace.formattedSize(probe.estimatedOutputSize))")
                        .foregroundStyle(Color.tbAccent)
                }
            }
            .monospacedDigit()
            .listRowBackground(Color.tbSurface)
        }
    }

    private func runningRow(_ item: DownscaleQueue.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: item.progress)
                .tint(.tbAccent)
            HStack {
                Text(item.progress.formatted(.percent.precision(.fractionLength(0))))
                Spacer()
                Text(remainingText(item.remaining))
            }
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(Color.tbInkSecondary)
            Text("可以離開 App，進度會顯示在動態島。")
                .font(.footnote)
                .foregroundStyle(Color.tbInkSecondary)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.tbSurface)
    }

    @ViewBuilder
    private func doneRows(_ outcome: DownscaleQueue.Outcome) -> some View {
        Group {
            LabeledContent("檔案大小", value: sizeChangeText(outcome))
            LabeledContent("空間音訊") {
                spatialResult(outcome)
            }
            LabeledContent("音軌", value: audioTracksText(outcome.audio))
            if let error = outcome.saveError {
                Label("沒有存到相簿：\(error)", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Color.tbDanger)
            } else {
                Label("已存到相簿", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.tbInk)
            }
        }
        .monospacedDigit()
        .listRowBackground(Color.tbSurface)
    }

    @ViewBuilder
    private func spatialResult(_ outcome: DownscaleQueue.Outcome) -> some View {
        let audio = outcome.audio
        if !audio.sourceHadSpatial {
            Text("原片沒有")
        } else if !outcome.keptSpatial {
            Label("只保留立體聲", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.tbWarning)
        } else if audio.spatialPreserved {
            Label("已保留", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.tbAccent)
        } else {
            Label("未保留", systemImage: "xmark.circle.fill")
                .foregroundStyle(Color.tbDanger)
        }
    }

    private func warningRow(_ text: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(text).foregroundStyle(color)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .listRowBackground(Color.tbSurface)
    }

    // MARK: 工具列與底部按鈕

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                queue.cleanUp()
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("關閉")
            .disabled(queue.isRunning)
        }
        if !queue.items.isEmpty && !queue.isRunning {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("加入影片")
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        Group {
            if queue.isRunning {
                Button {
                    queue.cancel()
                } label: {
                    Text("取消")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glass)
                .tint(.tbInk)
            } else if queue.readyCount > 0 {
                PrimaryButton(title: queue.readyCount > 1 ? "轉換 \(queue.readyCount) 支影片" : "開始轉換",
                              systemImage: "arrow.down.right.and.arrow.up.left") {
                    queue.start()
                }
            } else if queue.hasFinished {
                PrimaryButton(title: "再選其他影片", systemImage: "photo.on.rectangle") {
                    queue.reset()
                    showPicker = true
                }
            } else if queue.items.isEmpty {
                PrimaryButton(title: "從相簿選影片", systemImage: "photo.on.rectangle") {
                    showPicker = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: 文字

    private func resolutionText(_ probe: VideoProbe) -> String {
        let source = "\(Self.dimension(probe.displayWidth)) × \(Self.dimension(probe.displayHeight))"
        guard let output = probe.outputDisplaySize else { return source }
        return "\(source) → \(Self.dimension(output.width)) × \(Self.dimension(output.height))"
    }

    private static func dimension(_ value: Int) -> String {
        value.formatted(.number.grouping(.never))
    }

    static func mbps(_ bitsPerSecond: Int) -> String {
        let value = Measurement(value: Double(bitsPerSecond) / 1_000_000, unit: UnitInformationStorage.megabits)
        return value.formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                            numberFormatStyle: .number.precision(.fractionLength(1)))) + "/s"
    }

    private func remainingText(_ remaining: TimeInterval?) -> String {
        guard let remaining else { return "估算剩餘時間…" }
        let text = Duration.seconds(max(remaining, 1))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        return "剩餘約 \(text)"
    }

    private func sizeChangeText(_ outcome: DownscaleQueue.Outcome) -> String {
        let before = outcome.beforeSize, after = outcome.afterSize
        let base = "\(Workspace.formattedSize(before)) → \(Workspace.formattedSize(after))"
        guard before > 0 else { return base }
        let change = Double(after - before) / Double(before)
        return "\(base)（\(change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())))）"
    }

    private func audioTracksText(_ audio: DownscaleQueue.AudioCheckSummary) -> String {
        let output = audio.output.isEmpty ? "無" : audio.output.joined(separator: "、")
        if audio.tracksMatch { return "\(audio.output.count) 條一致（\(output)）" }
        let expected = audio.expected.isEmpty ? "無" : audio.expected.joined(separator: "、")
        return "預期 \(expected)，實際 \(output)"
    }
}
