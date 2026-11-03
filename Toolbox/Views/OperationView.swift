import SwiftUI
import QuickLook

struct OperationView: View {
    let operation: any ToolOperation
    let inputs: [URL]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: ParamValue]
    @State private var phase: Phase = .idle
    @State private var outputs: [URL] = []
    @State private var progressText = ""
    @State private var previewURL: URL?
    @State private var notice: String?
    @State private var task: Task<Void, Never>?
    @State private var fraction: Double = 0

    enum Phase: Equatable {
        case idle, running, done
        case failed(String)
    }

    init(operation: any ToolOperation, inputs: [URL]) {
        self.operation = operation
        self.inputs = inputs
        _values = State(initialValue: Params.defaults(for: operation.parameters))
    }

    private var usesCropEditor: Bool {
        operation.editor == .crop && inputs.count == 1
    }

    private var usesPagePicker: Bool {
        operation.editor == .pages && inputs.count == 1
    }

    private var visibleParameters: [ParameterSpec] {
        operation.parameters.filter { spec in
            if spec.key.hasPrefix("_") { return false }
            if usesCropEditor && spec.key == "ratio" { return false }
            if usesPagePicker && spec.key == "pages" { return false }
            return spec.isVisible(with: values)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if phase == .running {
                    runningSection
                } else if phase == .done {
                    resultSection
                    actionSection
                } else {
                    editorSections
                    settingsSections
                    inputSection
                    if case .failed(let message) = phase {
                        Section {
                            Label {
                                Text(message)
                                    .foregroundStyle(Color.tbDanger)
                            } icon: {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(Color.tbDanger)
                            }
                            .listRowBackground(Color.tbSurface)
                        }
                    }
                }
            }
            .tbGroundBackground()
            .listSectionSpacing(24)
            .navigationTitle(operation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        task?.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("關閉")
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .quickLookPreview($previewURL, in: outputs)
            .alert("工具箱", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好") { notice = nil }
            } message: {
                Text(notice ?? "")
            }
        }
        .tint(.tbAccent)
        .interactiveDismissDisabled(phase == .running)
    }

    // MARK: 設定

    @ViewBuilder
    private var editorSections: some View {
        if usesCropEditor {
            Section {
                CropEditor(url: inputs[0], ratio: binding(for: "ratio"), rect: binding(for: "_rect"))
                    .frame(height: 420)
                    .listRowInsets(EdgeInsets())
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .listRowBackground(Color.tbSurface)
        }
        if usesPagePicker {
            PDFPagePicker(url: inputs[0], pages: binding(for: "pages"))
                .listRowBackground(Color.tbSurface)
        }
    }

    /// 短選項用膠囊分段，自成一區；其他參數放在同一個「設定」區塊。
    @ViewBuilder
    private var settingsSections: some View {
        let specs = visibleParameters
        let capsules = specs.filter(Self.usesCapsules)
        let others = specs.filter { !Self.usesCapsules($0) }
        ForEach(capsules) { spec in
            Section {
                CapsuleSegments(options: spec.options ?? [],
                                selection: Binding(get: { values[spec.key]?.stringValue ?? "" },
                                                   set: { values[spec.key] = .string($0) }))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                Text(spec.title).foregroundStyle(Color.tbInkSecondary)
            } footer: {
                if let footer = spec.footer {
                    Text(footer).foregroundStyle(Color.tbInkSecondary)
                }
            }
        }
        if !others.isEmpty {
            Section {
                ForEach(others) { spec in
                    ParameterControl(spec: spec, value: binding(for: spec.key))
                        .listRowBackground(Color.tbSurface)
                }
            } header: {
                Text("設定").foregroundStyle(Color.tbInkSecondary)
            }
        }
    }

    static func usesCapsules(_ spec: ParameterSpec) -> Bool {
        guard spec.kind == .choice, let options = spec.options, (2...4).contains(options.count) else { return false }
        let longest = options.map(\.label.count).max() ?? 0
        return longest <= (options.count == 4 ? 4 : 6)
    }

    private var inputSection: some View {
        Section {
            ForEach(inputs.prefix(5), id: \.self) { url in
                ResultRow(url: url, meta: Workspace.formattedSize(Workspace.fileSize(url)))
                    .listRowBackground(Color.tbSurface)
            }
            if inputs.count > 5 {
                Text("還有 \(inputs.count - 5) 個檔案")
                    .font(.footnote)
                    .foregroundStyle(Color.tbInkSecondary)
                    .listRowBackground(Color.tbSurface)
            }
        } header: {
            Text("\(inputs.count) 個檔案 · \(Workspace.formattedSize(inputTotal))")
                .monospacedDigit()
                .foregroundStyle(Color.tbInkSecondary)
        } footer: {
            Text("全部在這台裝置上處理，檔案不會上傳。")
                .foregroundStyle(Color.tbInkSecondary)
        }
    }

    // MARK: 處理中

    private var runningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("處理中")
                    .font(.headline)
                    .foregroundStyle(Color.tbInk)
                ProgressView(value: fraction)
                    .tint(.tbAccent)
                Text(progressText.isEmpty ? "準備中…" : progressText)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.tbInkSecondary)
                    .lineLimit(2)
                Text("可以離開 App，進度會顯示在動態島。")
                    .font(.footnote)
                    .foregroundStyle(Color.tbInkSecondary)
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.tbSurface)
        }
    }

    // MARK: 底部按鈕

    @ViewBuilder
    private var bottomBar: some View {
        Group {
            switch phase {
            case .idle:
                PrimaryButton(title: "開始", action: start)
            case .failed:
                PrimaryButton(title: "再試一次", action: start)
            case .running:
                Button {
                    task?.cancel()
                } label: {
                    Text("取消")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glass)
                .tint(.tbInk)
            case .done:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: 結果

    private var resultSection: some View {
        Section {
            ForEach(Array(outputs.enumerated()), id: \.element) { index, url in
                Button {
                    previewURL = url
                } label: {
                    ResultRow(url: url, meta: meta(for: url, at: index))
                }
                .listRowBackground(Color.tbSurface)
            }
        } header: {
            Text(doneSummary)
                .monospacedDigit()
                .foregroundStyle(Color.tbInkSecondary)
        }
    }

    private var actionSection: some View {
        Section {
            if outputs.allSatisfy({ [FileKind.image, FileKind.video].contains(FileKind.detect($0)) }) {
                Button {
                    Task {
                        do {
                            try await PhotoSaver.save(outputs)
                            notice = "已存到照片"
                        } catch {
                            notice = error.localizedDescription
                        }
                    }
                } label: {
                    ExportLabel(title: "存到照片", systemImage: "square.and.arrow.down")
                }
                .listRowBackground(Color.tbSurface)
            }
            Button {
                do {
                    try Workspace.saveToDocuments(outputs)
                    notice = "已存到「檔案」App › 我的 iPhone › 工具箱 › 輸出"
                } catch {
                    notice = error.localizedDescription
                }
            } label: {
                ExportLabel(title: "存到「檔案」", systemImage: "folder.badge.plus")
            }
            .listRowBackground(Color.tbSurface)
            ShareLink(items: outputs) {
                ExportLabel(title: "分享全部", systemImage: "square.and.arrow.up")
            }
            .listRowBackground(Color.tbSurface)
            Button {
                model.replace(with: outputs)
                dismiss()
            } label: {
                ExportLabel(title: "接著處理這些檔案", systemImage: "arrow.uturn.left")
            }
            .listRowBackground(Color.tbSurface)
        }
    }

    private var inputTotal: Int64 {
        inputs.reduce(Int64(0)) { $0 + Workspace.fileSize($1) }
    }

    private var doneSummary: String {
        let after = outputs.reduce(Int64(0)) { $0 + Workspace.fileSize($1) }
        let kinds = Set(outputs.map(FileKind.detect))
        let label = kinds.count == 1 ? (kinds.first?.label ?? "檔案") : "檔案"
        return "\(outputs.count) 個\(label) · \(Workspace.formattedSize(inputTotal)) → \(Workspace.formattedSize(after))"
    }

    /// 一進一出時顯示大小變化，例如「4.2 MB → 1.1 MB（−74%）」。
    private func meta(for url: URL, at index: Int) -> String {
        let after = Workspace.fileSize(url)
        guard inputs.count == outputs.count, index < inputs.count else {
            return Workspace.formattedSize(after)
        }
        let before = Workspace.fileSize(inputs[index])
        guard before > 0 else { return Workspace.formattedSize(after) }
        let change = Int((Double(after - before) / Double(before) * 100).rounded())
        let sign = change > 0 ? "+" : (change < 0 ? "−" : "")
        return "\(Workspace.formattedSize(before)) → \(Workspace.formattedSize(after))（\(sign)\(abs(change))%）"
    }

    // MARK: 執行

    private func binding(for key: String) -> Binding<ParamValue> {
        Binding(
            get: { values[key] ?? .string("") },
            set: { values[key] = $0 }
        )
    }

    private func start() {
        phase = .running
        outputs = []
        progressText = ""
        fraction = 0
        let op = operation
        let files = inputs
        let current = values
        let background = BackgroundWork.begin(title: op.title, subtitle: "\(files.count) 個檔案・準備中")
        task = Task {
            let work = Task {
                try await Runner.run(op, inputs: files, values: current, progress: { value in
                    background.update(fraction: value)
                    Task { @MainActor in fraction = value }
                }) { text in
                    background.update(subtitle: text)
                    Task { @MainActor in progressText = text }
                }
            }
            background.onExpiration { work.cancel() }
            do {
                let result = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                background.finish(success: true)
                outputs = result
                phase = .done
            } catch is CancellationError {
                background.finish(success: false)
                phase = .idle
            } catch {
                background.finish(success: false)
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

struct ParameterControl: View {
    let spec: ParameterSpec
    @Binding var value: ParamValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            control
            if let footer = spec.footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch spec.kind {
        case .choice:
            Picker(spec.title, selection: stringBinding) {
                ForEach(spec.options ?? [], id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        case .toggle:
            Toggle(spec.title, isOn: Binding(get: { value.boolValue ?? false }, set: { value = .bool($0) }))
        case .number:
            VStack(alignment: .leading) {
                HStack {
                    Text(spec.title)
                    Spacer()
                    Text(numberText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(get: { value.doubleValue ?? 0 }, set: { value = .number($0) }),
                       in: range, step: spec.step ?? 1)
            }
        case .text:
            LabeledContent(spec.title) {
                TextField(spec.placeholder ?? "", text: stringBinding)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
    }

    private var stringBinding: Binding<String> {
        Binding(get: { value.stringValue }, set: { value = .string($0) })
    }

    private var range: ClosedRange<Double> {
        let low = spec.minValue ?? 0
        let high = Swift.max(spec.maxValue ?? 100, low + 1)
        return low...high
    }

    private var numberText: String {
        let number = value.doubleValue ?? 0
        let step = spec.step ?? 1
        let text = step >= 1 ? String(Int(number.rounded())) : String(format: "%.2f", number)
        return text + (spec.unit ?? "")
    }
}

/// 結果和輸入檔案列：縮圖、檔名、說明。
struct ResultRow: View {
    let url: URL
    let meta: String
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            FileThumbnail(image: thumbnail, kind: FileKind.detect(url))
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .foregroundStyle(Color.tbInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.tbInkSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 52)
        .task(id: url) { thumbnail = await Thumbnails.make(for: url) }
    }
}

/// 匯出動作列：灰色圖示、強調色文字。
struct ExportLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.tbInkSecondary)
                .frame(width: 28)
            Text(title)
                .foregroundStyle(Color.tbAccent)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
