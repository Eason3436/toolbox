import SwiftUI

/// 更新日誌：新的放最上面。每次更新加一筆，並同步改 project.yml 的 MARKETING_VERSION。
/// 版本號：大改版 → 第一碼；新功能 → 第二碼；只有修正 → 第三碼。
enum Changelog {
    struct Release: Identifiable {
        let version: String
        let date: String
        let title: String
        let items: [String]
        var id: String { version }
    }

    static var current: String { releases.first?.version ?? "" }

    static let releases: [Release] = [
        Release(version: "1.10.0", date: "2026-11-08", title: "買了什麼、用說的搜尋", items: [
            "消費分析新增「買了什麼」：把發票品項和記帳依種類分組（飲料、零食、正餐…），列出金額、常去的店和跟上月比",
            "分類交給裝置端模型，數字全部由 App 自己算，不會再出現對不上的內容；同一個月當天只整理一次",
            "搜尋可以直接用一句話，例如「上個月在全家買的飲料」「超過 500 的餐廳」，按搜尋後自動找出符合的紀錄",
            "搜尋也會找發票上的品項",
            "舊的「用地址當分店名」會自動查出真正的店名；查不到、或沒有地址的，分店顯示「未標注」",
            "設定 → 版本：可以看更新日誌",
        ]),
        Release(version: "1.9.0", date: "2026-11-08", title: "分店名稱、單色 logo", items: [
            "分店改成用地址去查附近同品牌的店名，不再直接放地址",
            "全家／FamilyMart、萊爾富／Hi-Life 等不同寫法自動合併成同一家",
            "訂閱在明細、詳情和訂閱頁都改成單色線條 logo",
            "修正：明細的上個月／下個月箭頭按不動",
            "修正：iCloud 雲碟選好資料夾後沒有反應",
            "消費分析改成直接用資料計算重點",
        ]),
        Release(version: "1.8.0", date: "2026-11-08", title: "訂閱 logo", items: [
            "訂閱和 App 內購顯示服務或平台的 logo（Apple Music、App Store、Netflix…）",
            "帳單頁不再分月，直接看全部；訂閱不顯示地圖",
            "每日、星期幾圖表標上金額",
        ]),
        Release(version: "1.7.0", date: "2026-11-08", title: "連鎖店與分店", items: [
            "連鎖店顯示 logo（7-ELEVEN、全家、麥當勞、萊爾富…）",
            "商家頁：總花費、各分店比較、分店選單、常買的東西",
            "設定 → 交易地點：多選記帳一次改分店",
            "設定 → 匯入發票照片：一次辨識多張，用時間和金額填進原本的記帳",
            "地圖卡片改成正方形，顯示縣市和行政區",
        ]),
        Release(version: "1.6.0", date: "2026-11-08", title: "主題色與 iCloud 同步", items: [
            "可以選 App 主色，或自訂顏色",
            "分類和膠囊改用會動的線條圖示",
            "iCloud 雲碟資料夾備份，多台裝置互相同步新增的紀錄",
            "介面配色更安靜",
        ]),
        Release(version: "1.5.0", date: "2026-11-07", title: "新分頁與消費分析", items: [
            "新的分頁配置：首頁、明細、分析、規劃、資產",
            "消費分析：分類比較、每天花多少、星期幾、常買的東西、花最多的商家",
            "明細可以篩選、往右滑再記一筆、單月／全部切換",
            "用發票地址或捷徑的位置找出是哪一家分店",
        ]),
        Release(version: "1.4.0", date: "2026-11-07", title: "新增畫面與動態島", items: [
            "新增畫面加上掃發票和一句話記帳",
            "首頁快速操作、即將到期的帳單、帳戶卡片",
            "改用原生分頁列，記好的一筆會飛進動態島",
            "依付款時間判斷早餐、午餐、點心",
        ]),
        Release(version: "1.3.0", date: "2026-11-07", title: "記帳詳情與自動分類", items: [
            "記帳詳情頁：發票內容、Apple Pay／LINE Pay 標示、商家地圖",
            "依商家自動分類",
            "支援 LiveContainer 捷徑收件匣",
            "可以刪除帳戶",
        ]),
        Release(version: "1.2.0", date: "2026-11-07", title: "資產分析", items: [
            "裝置端資產組合分析，會參考近期新聞和市場變化",
            "資產群組的走勢圖、可以重新命名",
        ]),
        Release(version: "1.1.0", date: "2026-11-07", title: "鍵盤與首頁", items: [
            "數字滾動動畫、底部金額鍵盤",
            "首頁可以自訂、收入帳單、更多圖表、分類樣式",
        ]),
        Release(version: "1.0.0", date: "2026-11-07", title: "第一版", items: [
            "記帳、帳戶、月曆熱度圖",
            "資產（股票、匯率報價）、預算、儲蓄目標、貸款",
            "子分類、月／年統計、備份與 CSV、Face ID",
            "匯入 Cashew 備份",
        ]),
    ]
}

struct ChangelogView: View {
    var body: some View {
        List {
            ForEach(Changelog.releases) { r in
                Section {
                    ForEach(r.items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                            Text(item).font(.subheadline)
                        }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.version).font(.headline).foregroundStyle(.primary).monospacedDigit()
                        Text(r.title).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text(r.date).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .textCase(nil)
                }
            }
        }
        .navigationTitle("更新日誌")
        .navigationBarTitleDisplayMode(.inline)
    }
}
