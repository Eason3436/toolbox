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
        Entry(version: "0.16.0", date: day(17), notes: [
            "新圖示：一張字卡加一個循環箭頭，背單字就是一直回來複習",
            "配色多四組：暖木、日曬、冰山、焦糖，一樣是設計師配好的低彩度色票",
        ]),
        Entry(version: "0.15.0", date: day(17), notes: [
            "每日提醒會真的跳通知了：到時間還有字要背才提醒，寫還有幾張要複習、幾個新字；背完那天就不吵",
            "桌面小工具：在 LiveContainer 的小工具裡選「App」再選 EnRecall，顯示還有幾張要背、連續幾天，點了直接打開",
        ]),
        Entry(version: "0.14.1", date: day(17), notes: [
            "PDF 講義例句裡的單字不會再被黑色塊蓋住",
        ]),
        Entry(version: "0.14.0", date: day(17), notes: [
            "設定 › 外觀可以換配色：黑白、北境、玫瑰松、常青、紙本、砂金，都是設計師配好的低彩度色票，淺色深色各一套",
            "單字 PDF 換新版面：講義是雙欄字卡、自測卷的答案在右邊往後折就蓋住、速查表照熟不熟分組；強調色跟著 App 的配色",
            "下面的分頁列捲動時不再縮小",
        ]),
        Entry(version: "0.13.0", date: day(16), notes: [
            "首頁新增「單字 PDF」：講義、自測卷、速查表，按「產生」一鍵做好，可以分享或列印",
            "牌組右上角也能把整副牌做成 PDF",
            "從 Claude 加進來的牌組和單字跟其他的一樣顯示，不再標來源",
        ]),
        Entry(version: "0.12.0", date: day(16), notes: [
            "同一個字可以同時在好幾個牌組，複習進度只有一份：從 Claude 送來的雜誌牌組會放齊整篇的字，不會只剩新字",
            "同一個字在兩個牌組，一天也只會考一次",
            "單字詳細多了「所在牌組」，可以放進別的牌組或移出；牌組列表往左滑也能移出",
        ]),
        Entry(version: "0.11.0", date: day(16), notes: [
            "首頁新增測驗：中翻英、英文填空、片語填空、句型填空，答錯的字可以排進今天的複習",
            "句型卡：Claude 整理好的雜誌句型（結構、可以放什麼詞、例句、變化、相近句型、常見錯誤）可以送進 App 背",
            "複習時切換「混合／新字／複習」從下一張開始，現在這張不會被換掉",
            "已下載的單字包會在背景補上測驗題，進度不變",
        ]),
        Entry(version: "0.10.0", date: day(16), notes: [
            "例句裡的單字用淡淡的螢光筆標出來",
            "複習畫面上方不再模糊",
            "剛打開時喇叭按鈕不會先變黑",
            "可以把複習成績分享給 Claude，請它分析或做複習講義（設定 › Claude 連接器）",
        ]),
        Entry(version: "0.9.0", date: day(16), notes: [
            "主畫面下方的分頁列只留圖示",
            "設定裡可以看更新日誌",
        ]),
        Entry(version: "0.8.0", date: day(16), notes: [
            "複習時點上方的「混合／新字／複習」直接切換，字會像拉霸一樣捲動",
            "上方時間軸改成小橢圓，顏色是前面每個字選的記憶程度",
            "「顯示答案」翻面時分開成四個評分按鈕，評完再併回一個",
            "捲動區的邊緣改成柔和淡出，停在頭尾時不會蓋到字",
        ]),
        Entry(version: "0.7.0", date: day(16), notes: [
            "卡片背面用分頁看例句、搭配、句型、近義字、易混淆、字源",
            "上方時間軸可以回頭看前面的卡，也能改當時的評分",
            "可以選只背新字、只複習或混合",
            "評分後不會再卡一下",
        ]),
        Entry(version: "0.6.0", date: day(16), notes: [
            "單字頁加上搭配、句型、片語、近義／反義字、易混淆字、相似字比較、常見錯誤、字源",
            "已下載的單字包會在背景補上這些內容，進度不變",
        ]),
        Entry(version: "0.5.0", date: day(16), notes: [
            "從單字商店下載學測 Level 1–6 和片語總表",
            "用 FSRS 安排複習，評分下面會顯示下次出現的時間",
            "可以復原上一張",
        ]),
        Entry(version: "0.4.0", date: day(16), notes: [
            "連接 Claude：在 Claude 加的單字，打開 App 會自動匯入",
        ]),
        Entry(version: "0.3.0", date: day(16), notes: [
            "第一版：首頁、牌組、紀錄、字典、設定",
        ]),
    ]

    private static func day(_ value: Int, month: Int = 11, year: Int = 2026) -> DateComponents {
        DateComponents(year: year, month: month, day: value)
    }

    var body: some View {
        List {
            ForEach(Self.entries) { entry in
                Section {
                    ForEach(entry.notes, id: \.self) { note in
                        Text(note)
                            .font(.body)
                            .foregroundStyle(Color.er.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    header(for: entry)
                }
                .listRowBackground(Color.er.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .erPageBackground()
        .navigationTitle("更新日誌")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(for entry: Entry) -> some View {
        HStack(spacing: 8) {
            Text(entry.version)
                .font(.erMono.weight(.semibold))
                .foregroundStyle(Color.er.text)
            if entry.version == AppConfig.shortVersion {
                Chip(text: "目前版本", style: .info)
            }
            Spacer(minLength: 8)
            if let date = Calendar.current.date(from: entry.date) {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.erMonoSmall)
                    .foregroundStyle(Color.er.textTertiary)
            }
        }
        .textCase(nil)
    }
}

#Preview("淺色") {
    NavigationStack {
        ChangelogView()
    }
    .previewEnvironment()
}

#Preview("深色") {
    NavigationStack {
        ChangelogView()
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
