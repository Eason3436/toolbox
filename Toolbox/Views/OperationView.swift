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

    private var visibleParameters: [ParameterSpec] {
        operation.parameters.filter { spec in
            if spec.key.hasPrefix("_") { return false }
            if usesCropEditor && spec.key == "ratio" { return false }
            return spec.isVisible(with: values)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if usesCropEditor {
                    Section {
                        CropEditor(url: inputs[0], ratio: binding(for: "ratio"), rect: binding(for: "_rect"))
                            .frame(height: 420)
                            .listRowInsets(EdgeInsets())
                    }
                }

                if !visibleParameters.isEmpty {
                    Section("設定") {
                        ForEach(visibleParameters) { spec in
                            ParameterControl(spec: spec, value: binding(for: spec.key))
                        }
                    }
                }

                Section {
                    Button(action: start) {
                        HStack {
                            Spacer()
                            if phase == .running {
                                ProgressView()
                            } else {
                                Text(phase == .done ? "再做一次" : "開始")
                                    .bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(phase == .running)
                    if phase == .running {
                        ProgressView(value: fraction)
                        if !progressText.isEmpty {
                            Text(progressText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("取消", role: .destructive) { task?.cancel() }
                    }
                } footer: {
                    Text("\(inputs.count) 個檔案，全部在這台裝置上處理。")
                }

                if case .failed(let message) = phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if !outputs.isEmpty {
                    resultSection
                    actionSection
                }
            }
            .navigationTitle(operation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
            .quickLookPreview($previewURL, in: outputs)
            .alert("完成", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好") { notice = nil }
            } message: {
                Text(notice ?? "")
            }
        }
    }

    // MARK: 結果

    private var resultSection: some View {
        Section {
            ForEach(outputs, id: \.self) { url in
                HStack(spacing: 12) {
                    Button {
                        previewURL = url
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: FileKind.detect(url).systemImage)
                                .frame(width: 28)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.primary)
                                Text(Workspace.formattedSize(Workspace.fileSize(url)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("結果")
        } footer: {
            Text(sizeSummary)
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
                    Label("存到照片", systemImage: "photo.badge.arrow.down")
                }
            }
            Button {
                do {
                    try Workspace.saveToDocuments(outputs)
                    notice = "已存到「檔案」App › 我的 iPhone › 工具箱 › 輸出"
                } catch {
                    notice = error.localizedDescription
                }
            } label: {
                Label("存到「檔案」", systemImage: "folder.badge.plus")
            }
            ShareLink(items: outputs) {
                Label("分享全部", systemImage: "square.and.arrow.up.on.square")
            }
            Button {
                model.replace(with: outputs)
                dismiss()
            } label: {
                Label("接著處理這些檔案", systemImage: "arrow.turn.down.right")
            }
        }
    }

    private var sizeSummary: String {
        let before = inputs.reduce(Int64(0)) { $0 + Workspace.fileSize($1) }
        let after = outputs.reduce(Int64(0)) { $0 + Workspace.fileSize($1) }
        guard before > 0 else { return "" }
        let change = Double(after - before) / Double(before) * 100
        let sign = change > 0 ? "+" : ""
        return "\(Workspace.formattedSize(before)) → \(Workspace.formattedSize(after))（\(sign)\(Int(change.rounded()))%）"
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
