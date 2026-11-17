import SwiftUI

/// 設定 → 更新日誌。每次更新在最上面加一筆，並同步改 project.yml 的 MARKETING_VERSION
struct ChangelogView: View {
    struct Entry: Identifiable {
        let version: String
        let date: DateComponents
        let notes: [String]

        var id: String { version }
    }

    static let entries: [Entry] = [
        Entry(version: "1.3.0", date: DateComponents(year: 2026, month: 11, day: 17), notes: [
            "整理照片時兩指捏小，可以看這張前後幾天的照片：左右滑換一天，點一下放進待刪除，兩指撐開回來",
            "影片照原本比例放在中間，上下和進度條下方都是模糊畫面",
            "影片右側按鈕加深底色，亮的畫面也看得清楚",
            "翻面看資訊不再卡一下：資訊先在背景讀好，地圖改成截圖",
            "整理畫面改成全螢幕蓋上去，按返回時排版不會跳",
        ]),
        Entry(version: "1.2.0", date: DateComponents(year: 2026, month: 11, day: 17), notes: [
            "後面那張照片平常淡淡、模糊的，不會跟前面那張的形狀打架；拖動時才慢慢變清楚",
            "點一下照片會翻過來，背面就是拍攝資訊、檔案和地圖；再點一下翻回來",
            "影片上下或左右的黑邊改成同一支影片的模糊畫面",
        ]),
        Entry(version: "1.1.0", date: DateComponents(year: 2026, month: 11, day: 17), notes: [
            "打開時這一組的照片從底部浮上來攤成扇子，點一下才開始整理",
            "整理畫面：上方返回、進度、分享；下方收藏、幾天前和地點（點一下看詳情）、復原",
            "按住往上拖，動態島會慢慢變大；放開照片就被吸進動態島",
            "背景換成目前這張照片的模糊版本",
        ]),
        Entry(version: "1.0.0", date: DateComponents(year: 2026, month: 11, day: 17), notes: [
            "照片頁：每次隨機抽一組，往左下一張、往右上一張、往上甩放進待刪除，可以復原",
            "分類：照片、截圖、自拍、原況照片、動圖；每組數量可以調",
            "影片頁：上下滑像短影音，自動循環播放；右側收藏、分享、刪除、復原",
            "刪除前先看縮圖確認，一次刪掉，系統確認視窗只跳一次",
            "照片詳情：拍攝設備、光圈、快門、ISO、焦距、檔案大小、地圖和地址",
            "統計：照片、截圖、影片各自的查看數、刪除數、騰出空間",
        ]),
    ]

    var body: some View {
        List {
            ForEach(Self.entries) { entry in
                Section {
                    ForEach(entry.notes, id: \.self) { note in
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    HStack {
                        Text(entry.version).font(.subheadline.monospacedDigit().weight(.semibold))
                        if entry.version == AppInfo.version {
                            Text("目前版本")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: .capsule)
                        }
                        Spacer()
                        if let date = Calendar.current.date(from: entry.date) {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .navigationTitle("更新日誌")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("淺色") {
    NavigationStack { ChangelogView() }
}

#Preview("深色") {
    NavigationStack { ChangelogView() }
        .preferredColorScheme(.dark)
}
