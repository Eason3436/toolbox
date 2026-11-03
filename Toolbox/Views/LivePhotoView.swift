import SwiftUI
import PhotosUI

struct LivePhotoView: View {
    @State private var items: [PhotosPickerItem] = []
    @State private var deleteOriginals = true
    @State private var running = false
    @State private var progress = (0, 0)
    @State private var summary: LivePhotoService.Summary?
    @State private var accessDenied = false

    var body: some View {
        Form {
            Section {
                Label {
                    Text("把原況照片的影片部分拿掉，只留下照片。每張大約可以省 2～3 MB。")
                } icon: {
                    Image(systemName: "livephoto.slash")
                }
                Label {
                    Text("會保留原始照片、景深（人像）、拍攝時間、地點、我的最愛與所在相簿，並盡量保留編輯與攝影風格。")
                } icon: {
                    Image(systemName: "checkmark.seal")
                }
            }

            Section {
                PhotosPicker(selection: $items, maxSelectionCount: nil, matching: .livePhotos, photoLibrary: .shared()) {
                    Label(items.isEmpty ? "選擇原況照片" : "已選 \(items.count) 張，重新選擇",
                          systemImage: "photo.stack")
                }
                Toggle("完成後刪除原本的原況照片", isOn: $deleteOriginals)
            } footer: {
                Text("刪除的照片會先移到「最近刪除」，清空之後空間才會真的釋放。")
            }

            Section {
                Button {
                    Task { await start() }
                } label: {
                    HStack {
                        Spacer()
                        if running {
                            ProgressView()
                            Text("  \(progress.0)/\(progress.1)")
                                .monospacedDigit()
                        } else {
                            Text("開始轉換").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(items.isEmpty || running)
            }

            if accessDenied {
                Section {
                    Label("需要完整的照片存取權限，請到「設定 › 工具箱 › 照片」改成「完整取用」。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if let summary {
                Section("結果") {
                    LabeledContent("已轉換", value: "\(summary.converted) 張")
                    if summary.skipped > 0 {
                        LabeledContent("不是原況照片，略過", value: "\(summary.skipped) 張")
                    }
                    if summary.lostEdits > 0 {
                        Text("有 \(summary.lostEdits) 張的編輯無法保留成可再調整的形式，已改存成編輯後的樣子。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if summary.deleted {
                        Text("原本的原況照片已移到「最近刪除」。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(summary.failures, id: \.self) { failure in
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("原況照片瘦身")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func start() async {
        guard await LivePhotoService.requestAccess() else {
            accessDenied = true
            return
        }
        accessDenied = false
        let identifiers = items.compactMap(\.itemIdentifier)
        guard !identifiers.isEmpty else { return }
        running = true
        summary = nil
        let background = BackgroundWork.begin(title: "原況照片瘦身", subtitle: "共 \(identifiers.count) 張")
        let result = await LivePhotoService.convert(identifiers: identifiers, deleteOriginals: deleteOriginals) { done, total in
            background.update(fraction: Double(done - 1) / Double(Swift.max(total, 1)))
            background.update(subtitle: "第 \(done)/\(total) 張")
            Task { @MainActor in progress = (done, total) }
        }
        background.finish(success: result.failures.isEmpty)
        summary = result
        running = false
        items = []
    }
}
