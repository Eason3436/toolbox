import SwiftUI

/// 每次更新的日期與內容。新的放最上面。
enum Changelog {
    struct Entry: Identifiable {
        let date: String
        let title: String
        let items: [String]
        var id: String { date + title }
    }

    static let entries: [Entry] = [
        Entry(date: "2026-11-06", title: "即時波形、15 分鐘摘要與備份", items: [
            "動態島外面的波形改成即時的，每秒跟著實際音量跳動",
            "即時動態和動態島加回「最近 15 分鐘摘要」按鈕",
            "設定 → 儲存空間與備份：把所有紀錄、筆記、課表和設定匯出成一個備份檔，之後可以全部還原（可選擇包含錄音檔）",
        ]),
        Entry(date: "2026-11-06", title: "儲存空間、動畫與即時動態", items: [
            "儲存空間改成用量長條圖，分全天錄音、課堂錄音、文字與筆記、學習記憶",
            "可以一次匯出所有文字紀錄",
            "動畫改成系統原生的平滑過場，數字變動會滾動",
            "即時動態與動態島照系統計時器和語音備忘錄的樣式重做：左邊圓形暫停與停止，右邊大計時，秒數滾動",
            "停止錄音後即時動態顯示「錄音已儲存」和總長度，15 分鐘後自動消失",
            "紀錄頁：分類切換固定在上方，課堂依日期分組",
            "設定最下面新增更新日誌",
            "照 Apple 設計規範調整：設定子頁標題一致、字級跟著系統字體大小、只有圖示的按鈕補上 VoiceOver 名稱、開啟「減少動態效果」時改用淡入淡出",
            "Siri 和捷徑的結果改成卡片：開始、暫停、繼續錄音時可以直接在卡片上暫停或停止；今日 Recap 和最近幾分鐘重點會顯示重點與待辦",
        ]),
        Entry(date: "2026-11-06", title: "介面重新整理", items: [
            "設定分成 AI、錄音與辨識、資料三組",
            "課堂頁最上面顯示現在這節課和開始按鈕，下面列出今天的課",
            "「歷史」改名「紀錄」，可以搜尋",
        ]),
        Entry(date: "2026-11-06", title: "Muse", items: [
            "AI 模型新增 Muse；選了 Muse 就不再用 Gemini 或 Apple Intelligence 寫筆記和摘要",
            "Muse 寫回來的整理直接顯示在 Recap 和課堂頁，支援 Markdown 和 HTML",
            "可以貼上整份課表",
            "Apple Intelligence 會確認這堂課是不是課表上那堂",
        ]),
        Entry(date: "2026-11-06", title: "匯入錄音檔", items: [
            "過去的課移到紀錄 → 課堂",
            "可以匯入語音備忘錄或其他錄音，轉成文字並整理成課堂筆記",
        ]),
        Entry(date: "2026-11-06", title: "用任何 AI 做筆記", items: [
            "一鍵匯出逐字稿和提示詞，貼給任何 AI 整理",
            "AI 給的 HTML 或 Markdown 筆記可以匯回來，用卡片排版顯示",
            "筆記開頭改成高層次摘要",
        ]),
        Entry(date: "2026-11-05", title: "同步", items: [
            "逐字稿和摘要同步到自己的 Supabase，Muse 可以讀取並寫回筆記",
        ]),
        Entry(date: "2026-11-04", title: "Whisper 補強與課表", items: [
            "AI 判斷辨識不好的段落，送 Groq Whisper 重新轉文字，每天有用量上限",
            "中文課只錄音，下課再轉文字，比較省電",
            "課表自動選科目；上課和講座有不同的筆記格式",
            "Gemini 忙碌時自動換模型",
            "Siri 與捷徑支援",
        ]),
        Entry(date: "2026-11-04", title: "辨識與筆記", items: [
            "自動省電：附近沒人說話時暫停收音",
            "可以改用 Gemini 整理，高中科目專有名詞，中英夾雜辨識",
            "詳細的課堂筆記與高層次摘要",
            "自訂詞彙與 AI 校正，辨識更準",
        ]),
        Entry(date: "2026-11-04", title: "第一版", items: [
            "全天錄音，背景也能收音",
            "裝置上轉文字，每天自動整理成 Recap",
            "課堂模式：即時字幕與翻譯",
            "追問、待辦加入提醒事項、排程錄音、即時動態",
        ]),
    ]

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version)（\(build)）"
    }

    static func dateText(_ iso: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: iso) else { return iso }
        return date.formatted(.dateTime.year().month().day())
    }
}

struct ChangelogView: View {
    var body: some View {
        List {
            ForEach(Changelog.entries) { entry in
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.title).font(.headline)
                        ForEach(entry.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(.tint).frame(width: 5, height: 5)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                                Text(item).font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(Changelog.dateText(entry.date))
                }
            }
        }
        .navigationTitle("更新日誌")
        .navigationBarTitleDisplayMode(.inline)
    }
}
