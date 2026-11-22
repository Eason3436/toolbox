import SwiftUI

/// 設定 → 關於 → 更新日誌。每次更新在最上面加一筆，並同步改 project.yml 的 MARKETING_VERSION
struct ChangelogView: View {
    struct Entry: Identifiable {
        let version: String
        let date: String
        let changes: [String]
        var id: String { version }
    }

    static let entries: [Entry] = [
        Entry(version: "0.4.2", date: "2026-11-22", changes: [
            "杜比 TrueHD（杜比無損音訊）的 MP4 有聲音了：App 自己把 TrueHD 解成無損 PCM 給播放器，5.1／7.1 都保留，全景聲的片子播 7.1 底層",
            "詳細頁標出「杜比 TrueHD」，不再顯示不支援的提醒",
        ]),
        Entry(version: "0.4.1", date: "2026-11-21", changes: [
            "播放更順：改成同時下載好幾段、先讀到前面，不再播十幾秒就停下來載入",
            "修正有些 HEVC 影片只有聲音、畫面一個 Q（檔案標成 hev1，播放時自動改成 iPhone 認得的 hvc1）",
            "有好幾條音軌時，自動換到 iPhone 能播的那條（例如 DTS 旁邊的 AAC）",
            "詳細頁會提醒 iPhone 內建播放器不支援的格式（DTS、TrueHD 音訊會沒有聲音；H.264 10-bit 影片只有聲音）",
        ]),
        Entry(version: "0.4.0", date: "2026-11-21", changes: [
            "首頁最上面加推薦輪播，左右滑或等幾秒自動換頁",
            "首頁加分類：類型、評分、發行年代、分級，點「全部」看所有分類",
            "詳細頁改用沒有字的海報，片名 logo 不會再跟海報上的字重疊；沒有無字海報時 logo 放在海報下面",
            "詳細頁海報上緣不再被淡掉；從頂端往下拉海報會跟著放大，不會露出空白",
            "劇集的每一集改成橫排、左右滑，一打開就停在下一集",
            "修正單集名稱重複寫兩次「第 X 集」",
            "檔案大小旁邊不再重複寫畫質（已經有畫質標籤）",
            "不在 TMDB 上的影片可以選「不需要配對」，用檔名當標題，放在首頁的「其他影片」",
            "新增更新日誌",
        ]),
        Entry(version: "0.3.0", date: "2026-11-21", changes: [
            "詳細頁改版：整張海報、片名 logo、海報主色的底、導演與演員表、相似內容",
            "讀影片規格，標出 4K／1080p、杜比視界、HDR10／HLG、杜比全景聲、5.1／7.1",
            "新增「設定 → 播放」：快轉間隔、長按倍速、繼續播放方式、片頭片尾、自動小窗等",
            "新增「設定 → 字幕和音軌」：外掛字幕、內嵌字幕語言、字幕樣式",
            "整個 App 的捲動邊緣改成柔和效果（iOS 26）",
        ]),
        Entry(version: "0.2.2", date: "2026-11-21", changes: [
            "修正詳細頁比螢幕寬、畫面破掉",
        ]),
        Entry(version: "0.2.1", date: "2026-11-21", changes: [
            "內建 Google 登入用戶端，可以直接登入",
        ]),
        Entry(version: "0.2.0", date: "2026-11-21", changes: [
            "TMDB API Key 改在 App 裡輸入、存在鑰匙圈，不再編進安裝檔",
        ]),
        Entry(version: "0.1.0", date: "2026-11-21", changes: [
            "第一版：Google 雲端硬碟登入、媒體庫掃描、TMDB 海報與資料、MP4／MOV 播放、續播與連續播放",
        ]),
    ]

    var body: some View {
        List {
            ForEach(Self.entries) { entry in
                Section {
                    ForEach(entry.changes, id: \.self) { change in
                        Text(change).font(.subheadline)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.version).font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Text(Self.format(entry.date)).font(.footnote)
                    }
                    .textCase(nil)
                }
            }
        }
        .navigationTitle("更新日誌")
        .navigationBarTitleDisplayMode(.inline)
        .softScrollEdges()
    }

    private static func format(_ s: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)?.formatted(date: .abbreviated, time: .omitted) ?? s
    }
}
