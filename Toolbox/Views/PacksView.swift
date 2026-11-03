import SwiftUI
import UniformTypeIdentifiers

struct PacksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var packs: [FeaturePack] = []
    @State private var showImporter = false
    @State private var showPaste = false
    @State private var pasted = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if packs.isEmpty {
                        Text("還沒有功能包")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(packs) { pack in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.title)
                                Text(pack.subtitle ?? pack.steps.map(\.op).joined(separator: " → "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("適用：" + pack.accepts.map(\.label).joined(separator: "、"))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        } icon: {
                            Image(systemName: pack.systemImage ?? "puzzlepiece.extension")
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { PackStore.delete(packs[index]) }
                        reload()
                    }
                } header: {
                    Text("已安裝")
                } footer: {
                    Text("功能包是一個 JSON 檔，把 App 內建的積木串成新功能。匯入後會出現在動作清單和捷徑裡，不用重新安裝 App。")
                }

                Section("新增") {
                    Button {
                        showImporter = true
                    } label: {
                        Label("從檔案匯入", systemImage: "folder")
                    }
                    Button {
                        pasted = UIPasteboard.general.string ?? ""
                        showPaste = true
                    } label: {
                        Label("貼上 JSON", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        install(PackStore.sampleJSON)
                    } label: {
                        Label("加入範例「XPan 分享用」", systemImage: "sparkles")
                    }
                }

                Section {
                    ForEach(Registry.builtIns.map { OperationBox(op: $0) }) { box in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(box.op.id)
                                .font(.callout.monospaced())
                            Text(box.op.title + " · " + box.op.parameters.filter { !$0.key.hasPrefix("_") }.map(\.key).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                } header: {
                    Text("可用的積木")
                } footer: {
                    Text("請 Claude 依照 README 裡的格式寫功能包時，可以把這份清單一起給它。")
                }
            }
            .navigationTitle("功能包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls { model.installPack(from: url) }
                reload()
            }
            .sheet(isPresented: $showPaste) {
                NavigationStack {
                    TextEditor(text: $pasted)
                        .font(.footnote.monospaced())
                        .padding(.horizontal)
                        .navigationTitle("貼上功能包 JSON")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("取消") { showPaste = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("安裝") {
                                    showPaste = false
                                    install(pasted)
                                }
                            }
                        }
                }
            }
            .alert("功能包", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: {
                Text(message ?? "")
            }
            .onAppear(perform: reload)
        }
    }

    private func install(_ json: String) {
        do {
            let pack = try PackStore.install(data: Data(json.utf8))
            model.packsVersion += 1
            message = "已安裝「\(pack.title)」"
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    private func reload() {
        packs = PackStore.loadAll()
    }
}
