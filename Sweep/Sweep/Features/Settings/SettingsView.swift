import SwiftUI
import Photos

struct SettingsView: View {
    @AppStorage(SettingsKey.groupSize) private var groupSize = SettingsDefault.groupSize
    @AppStorage(SettingsKey.excludeViewed) private var excludeViewed = true
    @AppStorage(SettingsKey.excludeFavorites) private var excludeFavorites = true
    @AppStorage(SettingsKey.hapticsOn) private var hapticsOn = true

    private var access: String {
        switch PhotoLibrary.authorizationStatus() {
        case .authorized: "完整取用"
        case .limited: "部分照片"
        case .denied, .restricted: "不允許"
        default: "還沒決定"
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("每組數量", selection: $groupSize) {
                    ForEach(SettingsDefault.groupSizes, id: \.self) { size in
                        Text("\(size.formatted()) 張").tag(size)
                    }
                }
            } footer: {
                Text("照片頁每次隨機抽幾張，從下一組開始生效。")
            }

            Section {
                Toggle("排除已看過的", isOn: $excludeViewed)
                Toggle("排除「我的最愛」", isOn: $excludeFavorites)
            } header: {
                Text("隨機抽選")
            } footer: {
                Text("看過的可以在「統計」重設，讓它們重新回到隨機池。")
            }

            Section {
                Toggle("觸覺回饋", isOn: $hapticsOn)
            }

            Section {
                LabeledContent("相簿權限", value: access)
                Button("到「設定」修改權限") { AppLinks.openSettings() }
            }

            Section {
                NavigationLink("更新日誌") { ChangelogView() }
                LabeledContent("版本", value: AppInfo.version)
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

#Preview("淺色") {
    NavigationStack { SettingsView() }
}

#Preview("深色") {
    NavigationStack { SettingsView() }
        .preferredColorScheme(.dark)
}
