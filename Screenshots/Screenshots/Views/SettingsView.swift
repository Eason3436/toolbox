import SwiftUI

struct SettingsView: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(\.openURL) private var openURL
    @AppStorage("importRange") private var importRange: ImportRange = .all

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("匯入範圍", selection: $importRange) {
                        ForEach(ImportRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    LabeledContent("目前截圖", value: "\(library.records.count.formatted()) 張")
                } header: {
                    Text("截圖")
                }

                Section {
                    LabeledContent("照片權限", value: accessText)
                    Button("開啟系統設定") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } footer: {
                    Text("選「完整取用」才能看到所有截圖。")
                }

                Section {
                    LabeledContent("版本", value: version)
                }
            }
            .navigationTitle("設定")
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
