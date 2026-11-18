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
        Entry(version: "0.11.1", date: day(18), notes: [
            "紀錄頁的牌組熟練度不再跟牌組名稱疊在一起，每個牌組一列，顯示已熟悉幾張",
            "每日複習的長條對齊下面的星期",
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
