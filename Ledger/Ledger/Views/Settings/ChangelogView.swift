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
        Release(version: "1.15.1", date: "2026-11-12", title: "記下後更快關閉", items: [
            "按「記下」後，波浪一掃完表單就關閉，不用再等邊框的顏色慢慢退掉",
        ]),
        Release(version: "1.15.0", date: "2026-11-11", title: "膠囊長條圖", items: [
            "商家的「最近 6 個月」和預算的「近 6 期」改成膠囊長條：灰色襯底，選中的那根用主題色漸層，上方大字顯示金額",
            "進場時長條一根一根長出來；點長條切換，彩色膠囊會滑過去、金額跟著滾動",
            "預算頁按上方箭頭換期間時，長條的選取也一起移動；超過預算的那期是紅色",
        ]),
        Release(version: "1.14.0", date: "2026-11-11", title: "記下的波浪", items: [
            "記一筆的數字鍵盤下方多了「記下」鍵，按下後彩色波浪從按鈕往上掃過，換成已記帳的畫面",
            "拿掉右上角的打勾，改用「記下」；鍵盤收起來時「記下」留在底部",
            "波浪有對應的震動，可在觸覺回饋設定的「記帳完成」關掉",
            "開啟「減少動態效果」時改成淡入淡出",
        ]),
        Release(version: "1.13.0", date: "2026-11-10", title: "觸覺回饋設定", items: [
            "設定 → 觸覺回饋：可以調整強度，放開滑桿會試震",
            "數字滾動、圖示動畫、金額鍵盤、記帳完成、刪除、選取與切換、其他，各自可以開關",
            "預設震動加強，強度調高時手感也更清楚",
            "切換分頁、拖曳圖表、選日期的震動也跟著強度設定",
        ]),
        Release(version: "1.12.0", date: "2026-11-10", title: "擬真觸覺回饋", items: [
            "數字滾動時會像機械計數器一樣一格一格地震，停住時「喀」一聲",
            "線條圖示播動畫時跟著震：鈴鐺左右敲、愛心撲通撲通、蓋章重重一下、掉下來「咚」…每個圖示依自己的動作",
            "金額鍵盤：數字鍵清脆、刪除鍵比較鈍，打錯時跟著數字左右抖三下",
            "記帳完成時，卡片咻地吸進動態島、撞進去、打勾，各有對應的震動",
            "刪除、隱藏金額、鍵盤收合也有手感",
            "設定可以關掉觸覺回饋",
        ]),
        Release(version: "1.11.2", date: "2026-11-10", title: "日期、箭頭與觸覺回饋", items: [
            "日期和月份依手機語系顯示，時間跟著 12／24 小時制設定",
            "上個月／下個月和列表箭頭改用會跟語言方向翻轉的圖示",
            "標記帳單已繳時有成功的震動；一句話記帳看不出金額時有提醒震動",
            "開啟「減少動態效果」時，記帳完成改成淡出，不飛進動態島",
        ]),
        Release(version: "1.11.1", date: "2026-11-10", title: "移除自動推測備註", items: [
            "從通知記帳不再自動在備註加上「推測：…」；分類一樣會參考以前同一家店的紀錄",
        ]),
        Release(version: "1.11.0", date: "2026-11-08", title: "地點搜尋、連鎖店圖示", items: [
            "更改地點的搜尋改成邊打邊出結果，找不到也可以直接用打的名稱當分店名",
            "修正：有時打開更改地點後無法搜尋",
            "記帳列表裡的連鎖店改用單色線條 logo，跟訂閱一樣",
            "匯入發票照片比對放寬：時間前後 36 小時、只有日期前後 2 天，店名對得上時金額可差 3%",
        ]),
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
