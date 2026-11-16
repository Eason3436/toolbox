import SwiftUI
import SwiftData

/// #Preview 用的假資料：in-memory ModelContainer + 商店清單
@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        let container = try! ModelContainer(for: Deck.self, Card.self, ReviewLog.self, configurations: config)
        seed(container.mainContext)
        return container
    }()

    static let emptyContainer: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: Deck.self, Card.self, ReviewLog.self, configurations: config)
    }()

    static let store = StoreModel(packs: packs)
    static let inbox = InboxService(previewCode: "Pv3kQ9wZr7TnB2xLm5HcY8dF")

    struct Sample {
        let word: String
        let phonetic: String
        let pos: String
        let zh: String
        let example: String
        let exampleZh: String
    }

    static let level4: [Sample] = [
        Sample(word: "accommodate", phonetic: "/əˈkɑːmədeɪt/", pos: "v.", zh: "容納；提供住宿", example: "The new library can accommodate 500 students.", exampleZh: "新圖書館可以容納 500 名學生。"),
        Sample(word: "accelerate", phonetic: "/əkˈseləreɪt/", pos: "v.", zh: "加速", example: "The car accelerated down the hill.", exampleZh: "車子加速衝下山坡。"),
        Sample(word: "access", phonetic: "/ˈækses/", pos: "n.", zh: "接近；使用權", example: "Students have access to the lab after school.", exampleZh: "學生放學後可以使用實驗室。"),
        Sample(word: "accompany", phonetic: "/əˈkʌmpəni/", pos: "v.", zh: "陪伴", example: "My mother accompanied me to the hospital.", exampleZh: "媽媽陪我去醫院。"),
        Sample(word: "accomplish", phonetic: "/əˈkɑːmplɪʃ/", pos: "v.", zh: "完成；達成", example: "We accomplished the task in two days.", exampleZh: "我們兩天就完成了這項任務。"),
        Sample(word: "reluctant", phonetic: "/rɪˈlʌktənt/", pos: "adj.", zh: "不情願的", example: "He was reluctant to admit his mistake.", exampleZh: "他不願意承認自己的錯誤。"),
        Sample(word: "record", phonetic: "/ˈrekərd/", pos: "n. / v.", zh: "n. 紀錄\nv. 記錄", example: "She broke the world record.", exampleZh: "她打破了世界紀錄。"),
        Sample(word: "ability", phonetic: "/əˈbɪləti/", pos: "n.", zh: "能力；才能", example: "Amy has the ability to learn new languages quickly.", exampleZh: "Amy 有快速學習新語言的能力。"),
    ]

    static let claudeWords: [Sample] = [
        Sample(word: "photosynthesis", phonetic: "", pos: "n.", zh: "光合作用", example: "Plants make their own food through photosynthesis.", exampleZh: "植物透過光合作用自己製造養分。"),
        Sample(word: "ecosystem", phonetic: "", pos: "n.", zh: "生態系", example: "Coral reefs are fragile ecosystems.", exampleZh: "珊瑚礁是脆弱的生態系。"),
        Sample(word: "erosion", phonetic: "", pos: "n.", zh: "侵蝕", example: "Trees help prevent soil erosion.", exampleZh: "樹木有助於防止土壤侵蝕。"),
    ]

    static func seed(_ context: ModelContext) {
        let now = Date()
        let day: TimeInterval = 86_400

        let l4 = Deck(id: "gsat-4", name: "學測 Level 4", kind: .storePack, mode: .active, order: .random, dailyNewLimit: 10, sortIndex: 0, packVersion: 2, level: 4)
        let custom = Deck(id: "custom:preview", name: "手寫單字 11/16", kind: .custom, mode: .active, dailyNewLimit: 5, sortIndex: 1)
        custom.lastImportedAt = now.addingTimeInterval(-3600)
        let l5 = Deck(id: "gsat-5", name: "學測 Level 5", kind: .storePack, mode: .paused, dailyNewLimit: 5, sortIndex: 2, packVersion: 2, level: 5)
        let phrases = Deck(id: "phrasebook", name: "學測片語總表", kind: .storePack, category: .phrase, dailyNewLimit: 5, sortIndex: 3, packVersion: 1)
        [l4, custom, l5, phrases].forEach(context.insert)

        for (i, s) in level4.enumerated() {
            let card = Card(id: Normalizer.wordID(s.word), word: s.word, pos: s.pos, zh: s.zh, example: s.example, exampleZh: s.exampleZh, phonetic: s.phonetic, sortIndex: i)
            if i < 5 {
                card.state = i < 3 ? .review : .learning
                card.stability = Double(5 + i * 8)
                card.difficulty = 5
                card.reps = i + 2
                card.lastReview = now.addingTimeInterval(-day * 2)
                card.due = now.addingTimeInterval(i < 4 ? -3600 : day * 3)
            }
            card.deck = l4
            context.insert(card)
        }
        for (i, s) in claudeWords.enumerated() {
            let card = Card(id: "claude:preview-\(i)", word: s.word, pos: s.pos, zh: s.zh, example: s.example, exampleZh: s.exampleZh, source: .claude, sortIndex: i)
            card.deck = custom
            context.insert(card)
        }
        let l5Card = Card(id: "w:surveillance", word: "surveillance", pos: "n.", zh: "監視", example: "The building is under 24-hour surveillance.", exampleZh: "這棟建築有 24 小時監控。", phonetic: "/sɜːrˈveɪləns/")
        l5Card.deck = l5
        context.insert(l5Card)
        let phrase = Card(id: "p:such as", word: "such as", pos: "轉折／連接用語", zh: "例如；像是", example: "Fruits such as apples and oranges are rich in vitamins.", exampleZh: "蘋果和柳橙等水果富含維生素。")
        phrase.deck = phrases
        context.insert(phrase)

        // 近 90 天的複習紀錄（固定的假資料，每次預覽都一樣）
        for offset in 0..<90 {
            let count = Int(StudyPlanner.stableHash("preview-\(offset)") % 9)
            for n in 0..<count * 4 {
                let log = ReviewLog(
                    cardId: "w:ability",
                    deckId: "gsat-4",
                    rating: Rating(rawValue: n % 4 + 1) ?? .good,
                    stateBefore: n % 5 == 0 ? .new : .review,
                    reviewedAt: now.addingTimeInterval(-Double(offset) * day - Double(n) * 60)
                )
                context.insert(log)
            }
        }
    }

    static let packs: [StorePack] = (1...6).map { level in
        StorePack(
            id: "gsat-\(level)", kind: "word", level: level,
            title: "學測 Level \(level)",
            subtitle: ["最基礎的生活單字", "國中到高一的常用字", "學測常考的核心字", "閱讀測驗常出現的字", "拉開分數的進階字", "最難的一級，頂標必備"][level - 1],
            desc: "大考中心《高中英文參考詞彙表》第 \(level) 級：字義、例句與中文翻譯。",
            author: "EnRecall", official: true, version: 2,
            words: [960, 993, 1006, 997, 998, 997][level - 1],
            updated: "2026-11-08",
            preview: [
                .init(w: "ability", zh: "能力；才能", pos: "n."),
                .init(w: "class", zh: "班級；課程；課堂", pos: "n."),
                .init(w: "front", zh: "前面的；正面的", pos: "adj."),
                .init(w: "happen", zh: "發生", pos: "v."),
            ],
            files: [.init(name: "level\(level).json", path: "store/gsat-\(level)/v2/level\(level).json.gz", size: 806_000, rawSize: 4_600_000)]
        )
    } + [
        StorePack(
            id: "phrasebook", kind: "phrase", level: nil, title: "學測片語總表", subtitle: "2,159 個學測片語",
            desc: "片語記憶卡的 2,159 個學測片語：詞性、用法、例句與翻譯。",
            author: "EnRecall", official: true, version: 2, words: 2159, updated: "2026-10-24",
            preview: [.init(w: "such as", zh: "例如；像是", pos: "轉折／連接用語")],
            files: [.init(name: "phrasebook.json", path: "phrasebook/v2/phrasebook.json.gz", size: 223_377, rawSize: 720_156)]
        ),
    ]
}

extension View {
    /// 預覽需要的環境：假資料、商店、toast、主色 tint
    @MainActor
    func previewEnvironment(empty: Bool = false) -> some View {
        self
            .modelContainer(empty ? PreviewData.emptyContainer : PreviewData.container)
            .environment(PreviewData.store)
            .environment(ToastCenter())
            .environment(PreviewData.inbox)
            .tint(Color.er.primary)
    }
}
