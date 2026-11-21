import SwiftUI

/// 設定 → 播放
struct PlaybackSettingsView: View {
    @AppStorage(Prefs.skipForward) private var skipForward = 10.0
    @AppStorage(Prefs.skipBackward) private var skipBackward = 10.0
    @AppStorage(Prefs.longPressRate) private var longPressRate = 2.0
    @AppStorage(Prefs.resumeMode) private var resumeMode = ResumeMode.resume
    @AppStorage(Prefs.autoPlayNext) private var autoPlayNext = true
    @AppStorage(Prefs.skipIntroOutro) private var skipIntroOutro = true
    @AppStorage(Prefs.autoMarkWatched) private var autoMarkWatched = true
    @AppStorage(Prefs.rememberSpeed) private var rememberSpeed = false
    @AppStorage(Prefs.autoPiP) private var autoPiP = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.cellularWarning) private var cellularWarning = true
    @AppStorage(Prefs.forwardBuffer) private var forwardBuffer = 0.0

    private let skipOptions: [Double] = [5, 10, 15, 30, 60]
    private let rateOptions: [Double] = [0, 1.5, 2, 3]
    private let bufferOptions: [Double] = [0, 30, 120, 300]

    var body: some View {
        Form {
            Section {
                Picker("快轉間隔", selection: $skipForward) {
                    ForEach(skipOptions, id: \.self) { Text(seconds($0)).tag($0) }
                }
                Picker("倒轉間隔", selection: $skipBackward) {
                    ForEach(skipOptions, id: \.self) { Text(seconds($0)).tag($0) }
                }
                Picker("長按倍速播放", selection: $longPressRate) {
                    ForEach(rateOptions, id: \.self) { rate in
                        Text(rate == 0 ? "關閉" : rate.formatted(.number.precision(.fractionLength(1))) + "x").tag(rate)
                    }
                }
                Picker("繼續播放", selection: $resumeMode) {
                    ForEach(ResumeMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("連續播放", isOn: $autoPlayNext)
                Toggle("自動跳過片頭片尾", isOn: $skipIntroOutro)
                Toggle("播放超過 95% 後自動標記為已觀看", isOn: $autoMarkWatched)
                Toggle("始終記住播放速度", isOn: $rememberSpeed)
            } footer: {
                Text("播放時在畫面左邊或右邊點兩下倒轉、快轉，按住畫面用倍速播放。片頭片尾的長度在每部劇的「⋯」裡設定。")
            }

            Section("背景播放與子母畫面") {
                Toggle("自動小窗播放", isOn: $autoPiP)
            }

            Section("回饋與提示") {
                Toggle("觸覺回饋", isOn: $haptics)
                Toggle("行動網路播放提醒", isOn: $cellularWarning)
            }

            Section {
                Picker("預先緩衝", selection: $forwardBuffer) {
                    ForEach(bufferOptions, id: \.self) { value in
                        Text(value == 0 ? "自動" : Duration.seconds(value).formatted(.units(allowed: [.minutes, .seconds], width: .wide))).tag(value)
                    }
                }
            } header: {
                Text("緩衝")
            } footer: {
                Text("網路不穩時可以先多緩衝一點，會用比較多記憶體與流量。「自動」讓系統決定。")
            }
        }
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
        .softScrollEdges()
    }

    private func seconds(_ value: Double) -> String {
        "\(Int(value)) 秒"
    }
}
