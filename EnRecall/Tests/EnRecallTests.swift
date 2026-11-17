import Testing
import Foundation
import SwiftData
@testable import EnRecall

struct NormalizerTests {
    @Test func trimsLowercasesAndCollapsesSpaces() {
        #expect(Normalizer.normalize("  Take   Care OF ") == "take care of")
        #expect(Normalizer.normalize("one\u{2019}s") == "one's")
        #expect(Normalizer.normalize("\u{2018}cause") == "'cause")
    }

    @Test func ids() {
        #expect(Normalizer.wordID(" Ability ") == "w:ability")
        #expect(Normalizer.phraseID("Such  as") == "p:such as")
    }
}

@MainActor
struct StudyPlannerTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Deck.self, Card.self, ReviewLog.self, CardContent.self, DeckLink.self, configurations: config)
        return ModelContext(container)
    }

    private func addCards(_ count: Int, to deck: Deck, in context: ModelContext, prefix: String) {
        for i in 0..<count {
            let card = Card(id: "\(prefix)\(i)", word: "\(prefix)\(i)", zh: "字", sortIndex: i)
            card.deck = deck
            context.insert(card)
        }
    }

    @Test func respectsGlobalAndDeckLimits() throws {
        let context = try makeContext()
        let a = Deck(id: "a", name: "A", kind: .storePack, dailyNewLimit: 3, sortIndex: 0)
        let b = Deck(id: "b", name: "B", kind: .storePack, dailyNewLimit: 10, sortIndex: 1)
        context.insert(a)
        context.insert(b)
        addCards(5, to: a, in: context, prefix: "a")
        addCards(5, to: b, in: context, prefix: "b")

        let plan = StudyPlanner.plan(decks: [a, b], logs: [], globalNewLimit: 6)
        #expect(plan.new.count == 6)
        #expect(plan.new.filter { $0.deck?.id == "a" }.count == 3)
        // 依序：A 的前三張
        #expect(plan.new.prefix(3).map(\.id) == ["a0", "a1", "a2"])
    }

    @Test func cardInTwoDecksIsPlannedOnce() throws {
        let context = try makeContext()
        let now = Date()
        let level = Deck(id: "gsat-3", name: "學測 Level 3", kind: .storePack, sortIndex: 0)
        let magazine = Deck(id: "custom:m", name: "Enjoy English 11/16", kind: .custom, sortIndex: 1)
        context.insert(level)
        context.insert(magazine)
        addCards(2, to: level, in: context, prefix: "w")
        let crispy = try #require(level.cards.first { $0.id == "w0" })
        crispy.state = .review
        crispy.due = now.addingTimeInterval(-60)
        DeckMembership.add(crispy, to: magazine, in: context)
        try context.save()

        #expect(magazine.activeCards.map(\.id) == ["w0"])
        let plan = StudyPlanner.plan(decks: [level, magazine], logs: [], globalNewLimit: 10, now: now)
        #expect(plan.due.map(\.id) == ["w0"])
        #expect(plan.deckOf["w0"] == "gsat-3")

        // 只複習雜誌牌組：一樣是同一張卡
        let only = StudyPlanner.plan(decks: [magazine], logs: [], globalNewLimit: 10, now: now)
        #expect(only.due.first === crispy)
        #expect(only.deckOf["w0"] == "custom:m")

        // 移出雜誌牌組：卡片和進度還在學測牌組
        #expect(DeckMembership.remove(crispy, from: magazine, in: context))
        try context.save()
        #expect(magazine.activeCards.isEmpty)
        #expect(crispy.deck?.id == "gsat-3")
        #expect(crispy.state == .review)
        // 原本的牌組不能移出
        #expect(!DeckMembership.remove(crispy, from: level, in: context))
    }

    @Test func pausedAndReviewOnlyDecks() throws {
        let context = try makeContext()
        let now = Date()
        let paused = Deck(id: "p", name: "P", kind: .storePack, mode: .paused, sortIndex: 0)
        let reviewOnly = Deck(id: "r", name: "R", kind: .storePack, mode: .reviewOnly, sortIndex: 1)
        context.insert(paused)
        context.insert(reviewOnly)
        addCards(3, to: paused, in: context, prefix: "p")
        addCards(3, to: reviewOnly, in: context, prefix: "r")
        for card in paused.cards + reviewOnly.cards {
            card.state = .review
            card.due = now.addingTimeInterval(-60)
        }
        if let fresh = reviewOnly.cards.first { fresh.state = .new }

        let plan = StudyPlanner.plan(decks: [paused, reviewOnly], logs: [], globalNewLimit: 20, now: now)
        #expect(plan.new.isEmpty)
        #expect(plan.due.count == 2)
        #expect(plan.due.allSatisfy { $0.deck?.id == "r" })
    }

    @Test func newCardsLearnedTodayCountAgainstLimit() throws {
        let context = try makeContext()
        let now = Date()
        let deck = Deck(id: "d", name: "D", kind: .storePack, dailyNewLimit: 5, sortIndex: 0)
        context.insert(deck)
        addCards(10, to: deck, in: context, prefix: "d")
        let logs = (0..<4).map { i in
            ReviewLog(cardId: "x\(i)", deckId: "d", rating: .good, stateBefore: .new, reviewedAt: now.addingTimeInterval(-60))
        }
        let plan = StudyPlanner.plan(decks: [deck], logs: logs, globalNewLimit: 20, now: now)
        #expect(plan.new.count == 1)
    }

    @Test func randomOrderIsStableWithinADay() throws {
        let context = try makeContext()
        let deck = Deck(id: "r", name: "R", kind: .storePack, order: .random, dailyNewLimit: 5, sortIndex: 0)
        context.insert(deck)
        addCards(30, to: deck, in: context, prefix: "r")
        let now = Date()
        let first = StudyPlanner.plan(decks: [deck], logs: [], globalNewLimit: 20, now: now).new.map(\.id)
        let second = StudyPlanner.plan(decks: [deck], logs: [], globalNewLimit: 20, now: now.addingTimeInterval(1)).new.map(\.id)
        #expect(first == second)
        #expect(first.count == 5)
    }
}

struct ReviewMixTests {
    @Test func mixedSpreadsNewCardsBetweenReviews() {
        let due = ["r1", "r2", "r3", "r4"]
        #expect(StudyPlanner.arrange(due: due, new: ["n1"], mix: .mixed) == ["r1", "r2", "n1", "r3", "r4"])
        #expect(StudyPlanner.arrange(due: ["r1", "r2", "r3"], new: ["n1", "n2", "n3"], mix: .mixed) == ["r1", "n1", "r2", "n2", "r3", "n3"])
        #expect(StudyPlanner.arrange(due: [], new: ["n1", "n2"], mix: .mixed) == ["n1", "n2"])
        #expect(StudyPlanner.arrange(due: due, new: ["n1"], mix: .newOnly) == ["n1"])
        #expect(StudyPlanner.arrange(due: due, new: ["n1"], mix: .reviewOnly) == due)
        let many = StudyPlanner.arrange(due: Array(repeating: "r", count: 7), new: Array(repeating: "n", count: 20), mix: .mixed)
        #expect(many.count == 27)
        #expect(many.filter { $0 == "n" }.count == 20)
    }
}

@MainActor
struct StudySnapshotTests {
    @Test func includesLearnedCardsAndRecentLogsOnly() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Deck.self, Card.self, ReviewLog.self, CardContent.self, DeckLink.self, configurations: config)
        let context = ModelContext(container)
        let deck = Deck(id: "gsat-4", name: "學測 Level 4", kind: .storePack, dailyNewLimit: 10, sortIndex: 0)
        context.insert(deck)
        let learned = Card(id: "w:absolute", word: "absolute", zh: "完全的", sortIndex: 0)
        learned.deck = deck
        learned.state = .review
        learned.stability = 30
        learned.reps = 3
        learned.lapses = 1
        learned.lastReview = Date()
        let fresh = Card(id: "w:abandon", word: "abandon", zh: "放棄", sortIndex: 1)
        fresh.deck = deck
        context.insert(learned)
        context.insert(fresh)
        let magazine = Deck(id: "custom:m", name: "雜誌", kind: .custom, sortIndex: 1)
        context.insert(magazine)
        DeckLink.insert(deck: magazine, card: learned, sortIndex: 0, into: context)
        context.insert(ReviewLog(cardId: "w:absolute", deckId: "gsat-4", rating: .good, stateBefore: .review, scheduledDays: 6))
        context.insert(ReviewLog(cardId: "w:absolute", deckId: "gsat-4", rating: .again, stateBefore: .new,
                                 reviewedAt: Date().addingTimeInterval(-200 * 86_400)))
        try context.save()

        let snapshot = try StudySnapshot.make(context: context)
        #expect(snapshot.cards.map(\.id) == ["w:absolute"])
        #expect(snapshot.logs.count == 1)
        #expect(snapshot.decks.first?.total == 2)
        #expect(snapshot.decks.first?.new == 1)
        #expect(snapshot.decks.first?.mastered == 1)
        // 同一張卡在兩個牌組：只傳一次，decks 列出兩個
        #expect(snapshot.decks.last?.total == 1)
        #expect(snapshot.cards.first?.decks == ["gsat-4", "custom:m"])
        #expect(Set(snapshot.cardIds) == ["w:absolute", "w:abandon"])

        let body = try StudySnapshot.requestBody(code: "TestCodeTestCodeTest1234", snapshot: snapshot)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["p_code"] as? String == "TestCodeTestCodeTest1234")
        let payload = try #require(json["p_payload"] as? [String: Any])
        #expect(payload["v"] as? Int == 1)
        #expect(payload["daily_new_limit"] != nil)
        let card = try #require((payload["cards"] as? [[String: Any]])?.first)
        #expect(card["last_review"] is String)
        #expect(card["state"] as? String == "review")
        #expect(card["decks"] as? [String] == ["gsat-4", "custom:m"])
        #expect((payload["card_ids"] as? [String])?.count == 2)
    }
}

struct StatsCalculatorTests {
    @Test func heatLevels() {
        #expect(StatsCalculator.heatLevel(0, max: 10) == 0)
        #expect(StatsCalculator.heatLevel(1, max: 10) == 1)
        #expect(StatsCalculator.heatLevel(10, max: 10) == 4)
        #expect(StatsCalculator.heatLevel(5, max: 10) == 2)
    }
}

@MainActor
struct InboxImporterTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Deck.self, Card.self, ReviewLog.self, CardContent.self, DeckLink.self, configurations: config)
        return ModelContext(container)
    }

    private func item(_ word: String, deck: String = "第 3 課", pos: String? = "n.", libraryID: String? = nil) -> InboxItem {
        InboxItem(
            id: UUID().uuidString, deckName: deck, word: word, pos: pos, zh: "中文",
            example: "Example.", exampleZh: "例句。",
            source: libraryID == nil ? "claude" : "library", libraryWordId: libraryID
        )
    }

    @Test func createsDeckAndCards() throws {
        let context = try makeContext()
        let result = try InboxImporter.importItems([
            item("ability", libraryID: "w:ability"),
            item("photosynthesis"),
        ], into: context)
        #expect(result.added == 2)
        #expect(result.decks == ["第 3 課"])
        let decks = try context.fetch(FetchDescriptor<Deck>())
        #expect(decks.count == 1)
        #expect(decks.first?.kind == .custom)
        let cards = try context.fetch(FetchDescriptor<Card>())
        #expect(Set(cards.map(\.source)) == [.library, .claude])
        #expect(cards.contains { $0.id == "w:ability" })
        #expect(result.toastMessage == "從 Claude 匯入 2 個單字到〈第 3 課〉")
    }

    @Test func sendingTheSameWordsTwiceDoesNotDuplicate() throws {
        let context = try makeContext()
        let batch = [item("ability", libraryID: "w:ability"), item("photosynthesis"), item("Photosynthesis ")]
        let first = try InboxImporter.importItems(batch, into: context)
        #expect(first.added == 2)
        #expect(first.skipped == 1)
        let second = try InboxImporter.importItems(batch, into: context)
        #expect(second.added == 0)
        #expect(second.skipped == 3)
        #expect(try context.fetch(FetchDescriptor<Card>()).count == 2)
    }

    @Test func libraryWordAlreadyInAnotherDeckKeepsProgress() throws {
        let context = try makeContext()
        let pack = Deck(id: "gsat-1", name: "學測 Level 1", kind: .storePack, level: 1)
        context.insert(pack)
        let card = Card(id: "w:ability", word: "ability", zh: "能力")
        card.state = .review
        card.reps = 5
        card.deck = pack
        context.insert(card)

        let result = try InboxImporter.importItems([item("ability", libraryID: "w:ability"), item("photosynthesis")], into: context)
        #expect(result.added == 2)
        #expect(result.linked == 1)
        #expect(result.skipped == 0)
        #expect(result.toastMessage == "從 Claude 匯入 2 個單字到〈第 3 課〉，其中 1 個本來就在背，進度照舊")
        // 同一張卡：原本的牌組不變、進度不變，也出現在第 3 課
        #expect(card.reps == 5)
        #expect(card.deck?.id == "gsat-1")
        #expect(try context.fetch(FetchDescriptor<Card>()).count == 2)
        let lesson = try #require(try context.fetch(FetchDescriptor<Deck>()).first { $0.name == "第 3 課" })
        #expect(Set(lesson.activeCards.map(\.id)) == ["w:ability", lesson.cards.first?.id ?? ""])
        #expect(card.allDecks.map(\.id) == ["gsat-1", lesson.id])

        // 再送一次：已經在這個牌組，不會多一筆
        let again = try InboxImporter.importItems([item("ability", libraryID: "w:ability")], into: context)
        #expect(again.added == 0)
        #expect(again.skipped == 1)
        #expect(try context.fetch(FetchDescriptor<DeckLink>()).count == 1)
    }

    @Test func samePhraseDifferentPosIsKept() throws {
        let context = try makeContext()
        let result = try InboxImporter.importItems([item("record", pos: "n."), item("record", pos: "v.")], into: context)
        #expect(result.added == 2)
    }
}

struct PairingCodeTests {
    @Test func generatedCodesMatchServerFormat() {
        for _ in 0..<50 {
            let code = PairingCodeStore.generate()
            #expect(code.count == 24)
            #expect(PairingCodeStore.isValid(code))
        }
        #expect(!PairingCodeStore.isValid("short"))
        #expect(!PairingCodeStore.isValid("has space in the code xx"))
    }
}

struct GzipTests {
    private func gzip(_ text: String, withName: Bool) throws -> Data {
        let deflate = try (Data(text.utf8) as NSData).compressed(using: .zlib) as Data
        var header: [UInt8] = [0x1f, 0x8b, 0x08, withName ? 0x08 : 0x00, 0, 0, 0, 0, 0x02, 0xff]
        if withName { header += Array("level1.json".utf8) + [0] }
        return Data(header) + deflate + Data(repeating: 0, count: 8)
    }

    @Test func decompressesGzipWithAndWithoutFileName() throws {
        let json = #"{"version":2,"words":[]}"#
        #expect(try Gzip.decompress(gzip(json, withName: true)) == Data(json.utf8))
        #expect(try Gzip.decompress(gzip(json, withName: false)) == Data(json.utf8))
    }

    @Test func plainJSONPassesThrough() throws {
        let data = Data(#"{"a":1}"#.utf8)
        #expect(try Gzip.decompress(data) == data)
    }
}

struct PackParserTests {
    @Test func wordMappingFollowsSharedRules() throws {
        let level = #"""
        {"version":2,"words":[
          {"word":"record","phonetic":"/ˈrekərd/","meanings":[
            {"pos":"n.","zh":"紀錄","examples":[]},
            {"pos":"v.","zh":"記錄","examples":[{"en":"Record it.","zh":"記下來。"}]}]},
          {"word":"ability","meanings":[
            {"pos":"n.","zh":"能力","examples":[{"en":"A.","zh":"甲。"}]},
            {"pos":"n.","zh":"才能","examples":[]}]}
        ]}
        """#
        let fixes = #"{"version":3,"words":[{"word":"Dr.","meanings":[{"pos":"abbr.","zh":"醫生","examples":[]}]}]}"#
        let entries = try PackParser.entries(files: [
            (name: "fixes-level2.json", data: Data(fixes.utf8)),
            (name: "level2.json", data: Data(level.utf8)),
        ])
        #expect(entries.map(\.id) == ["w:record", "w:ability", "w:dr."])
        #expect(entries[0].pos == "n. / v.")
        #expect(entries[0].zh == "n. 紀錄\nv. 記錄")
        #expect(entries[0].example == "Record it.")
        #expect(entries[1].pos == "n.")
        #expect(entries[1].zh == "能力；才能")
        #expect(entries[2].word == "Dr.")
        #expect(entries[2].example == nil)
    }

    @Test func phrases() throws {
        let book = #"{"version":2,"format":2,"items":[{"no":1,"p":"rely on sb/sth","zh":"依賴","pos":"動詞片語","ex":"Rely on me.","exZh":"靠我。"}]}"#
        let entries = try PackParser.entries(files: [(name: "phrasebook.json", data: Data(book.utf8))])
        #expect(entries.first?.id == "p:rely on sb/sth")
        #expect(entries.first?.exampleZh == "靠我。")
        let detail = try #require(entries.first?.detail).decodedDetail()
        #expect(detail.phrase?.p == "rely on sb/sth")
        #expect(detail.word == nil)
    }

    @Test func fullDetailIsKeptAndSimilarPairsAttachToBothWords() throws {
        let level = #"""
        {"version":2,"words":[
          {"word":"abstract","forms":"abstractly","meanings":[
            {"pos":"adj.","zh":"抽象的","ext":"抽掉細節","examples":[{"en":"An abstract idea.","zh":"抽象概念。"}],
             "patterns":[{"pattern":"abstract + N","en":"abstract ideas","zh":"抽象的想法"}],
             "collocations":[{"en":"abstract art","zh":"抽象藝術","star":false},{"en":"abstract idea","zh":"抽象概念","star":true}]},
            {"pos":"n.","zh":"摘要","examples":[],"collocations":[{"en":"Abstract Idea","star":true},{"en":"write an abstract","star":true}]}],
           "synonyms":[{"word":"theoretical","note":"理論上的","example":"theoretical question","tag":["gsat"]},{"bad":1}],
           "antonyms":"concrete",
           "breakdown":[{"part":"abs-","type":"字首","gloss":"離開"}],
           "origin":"  ",
           "related":[{"word":"extract","note":"取出"}]},
          {"word":"extract","meanings":[{"pos":"v.","zh":"取出","examples":[]}]},
          {"meanings":[{"pos":"n.","zh":"沒有字"}]}
        ]}
        """#
        let similar = #"{"version":1,"pairs":[{"a":"abstract","b":"extract","diff":"差在字首","points":["abs-","ex-"],"exA":{"en":"A."}},{"a":"x"}]}"#
        let entries = try PackParser.entries(files: [
            (name: "similar-level4.json", data: Data(similar.utf8)),
            (name: "level4.json", data: Data(level.utf8)),
        ])
        #expect(entries.map(\.id) == ["w:abstract", "w:extract"])

        let detail = try #require(entries[0].detail).decodedDetail()
        let word = try #require(detail.word)
        #expect(word.forms == "abstractly")
        #expect(word.meanings.first?.ext == "抽掉細節")
        #expect(word.meanings.first?.patterns.first?.pattern == "abstract + N")
        // 常用的排前面、大小寫不同算同一個
        #expect(word.allCollocations.map(\.en) == ["abstract idea", "write an abstract", "abstract art"])
        #expect(word.synonyms.map(\.word) == ["theoretical"])
        #expect(word.antonyms.isEmpty)
        #expect(word.origin == nil)
        #expect(word.breakdown.first?.gloss == "離開")
        #expect(word.related.first?.word == "extract")
        #expect(detail.similar?.first?.diff == "差在字首")
        #expect(detail.similar?.first?.exA?.en == "A.")

        let other = try #require(entries[1].detail).decodedDetail()
        #expect(other.similar?.first?.b == "extract")
    }
}

private extension Data {
    func decodedDetail() throws -> CardDetail {
        try JSONDecoder().decode(CardDetail.self, from: self)
    }
}

@MainActor
struct PackInstallerTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Deck.self, Card.self, ReviewLog.self, CardContent.self, DeckLink.self, configurations: config)
        return ModelContext(container)
    }

    private func pack(version: Int) -> StorePack {
        StorePack(id: "gsat-1", kind: "word", level: 1, title: "學測 Level 1", subtitle: nil, desc: nil, author: nil,
                  official: true, version: version, words: 3, updated: nil, preview: nil, files: [])
    }

    private func entry(_ word: String, zh: String = "中文") -> LibraryEntry {
        LibraryEntry(id: Normalizer.wordID(word), word: word, pos: "n.", zh: zh, example: nil, exampleZh: nil, phonetic: nil)
    }

    @Test func updateKeepsProgressAndRetiresRemovedWords() throws {
        let context = try makeContext()
        try PackInstaller.install(pack(version: 1), entries: [entry("ability"), entry("class"), entry("front")], into: context)
        let ability = try #require(try context.fetch(FetchDescriptor<Card>()).first { $0.id == "w:ability" })
        let due = Date().addingTimeInterval(86_400 * 7)
        ability.state = .review
        ability.stability = 12
        ability.due = due
        ability.reps = 4

        let result = try PackInstaller.install(pack(version: 2), entries: [entry("ability", zh: "能力；才能"), entry("class"), entry("happen")], into: context)
        #expect(result.isUpdate)
        #expect(result.added == 1)
        #expect(result.retired == 1)
        #expect(ability.zh == "能力；才能")
        #expect(ability.stability == 12)
        #expect(ability.due == due)
        #expect(ability.reps == 4)
        let decks = try context.fetch(FetchDescriptor<Deck>())
        #expect(decks.count == 1)
        #expect(decks.first?.packVersion == 2)
        #expect(decks.first?.activeCards.count == 3)
    }

    @Test func oldContentFormatShowsAsUpdateAndReinstallFillsDetail() throws {
        let context = try makeContext()
        try PackInstaller.install(pack(version: 2), entries: [entry("ability")], into: context)
        let deck = try #require(try context.fetch(FetchDescriptor<Deck>()).first)
        let card = try #require(deck.cards.first)
        card.reps = 5
        // 模擬舊版 App 裝的牌組：沒有完整內容
        deck.contentFormat = 0
        let store = StoreModel(packs: [pack(version: 2)])
        #expect(store.status(of: pack(version: 2), decks: [deck]) == .updateAvailable)

        var withDetail = entry("ability")
        withDetail.detail = Data("{}".utf8)
        try PackInstaller.install(pack(version: 2), entries: [withDetail], into: context)
        #expect(deck.contentFormat == PackInstaller.contentFormat)
        let content = try #require(try context.fetch(FetchDescriptor<CardContent>()).first)
        #expect(content.id == "w:ability")
        #expect(content.data == Data("{}".utf8))
        #expect(CardDetail.load(for: "w:ability", in: context) == CardDetail(word: nil, phrase: nil, similar: nil))
        #expect(card.reps == 5)
        #expect(store.status(of: pack(version: 2), decks: [deck]) == .downloaded)
    }

    @Test func wordAlreadyImportedFromClaudeStaysInItsDeck() throws {
        let context = try makeContext()
        let custom = Deck(id: "custom:x", name: "第 3 課", kind: .custom)
        context.insert(custom)
        let card = Card(id: "w:ability", word: "ability", zh: "能力")
        card.reps = 3
        card.deck = custom
        context.insert(card)

        let result = try PackInstaller.install(pack(version: 1), entries: [entry("ability"), entry("class")], into: context)
        #expect(result.added == 1)
        #expect(card.deck?.id == "custom:x")
        #expect(card.reps == 3)
        #expect(try context.fetch(FetchDescriptor<Card>()).count == 2)
        // 等級牌組也看得到這個字（同一張卡）
        let level = try #require(try context.fetch(FetchDescriptor<Deck>()).first { $0.id == "gsat-1" })
        #expect(level.activeCards.count == 2)
        #expect(level.orderedActiveCards.map(\.id) == ["w:ability", "w:class"])

        // 單字包拿掉這個字：只解除連結，卡片還在第 3 課
        try PackInstaller.install(pack(version: 2), entries: [entry("class")], into: context)
        try context.save()
        #expect(level.activeCards.map(\.id) == ["w:class"])
        #expect(card.deck?.id == "custom:x")
        #expect(!card.isRetired)
    }
}

struct FSRSTests {
    private let scheduler = FSRSScheduler()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var newCard: CardMemory {
        CardMemory(state: .new, stability: 0, difficulty: 0, due: now, lastReview: nil, reps: 0, lapses: 0)
    }

    @Test func newCardSteps() {
        let preview = scheduler.preview(newCard, now: now)
        #expect(preview[.again]?.memory.state == .learning)
        #expect(preview[.again]?.memory.due == now.addingTimeInterval(60))
        #expect(preview[.good]?.memory.due == now.addingTimeInterval(600))
        #expect(preview[.easy]?.memory.state == .review)
        #expect((preview[.easy]?.scheduledDays ?? 0) >= 1)
    }

    @Test func reviewIntervalsAreOrdered() {
        let learned = scheduler.next(scheduler.next(newCard, rating: .good, now: now).memory, rating: .good, now: now.addingTimeInterval(600))
        #expect(learned.memory.state == .review)
        let later = now.addingTimeInterval(learned.scheduledDays * 86_400)
        let preview = scheduler.preview(learned.memory, now: later)
        let hard = preview[.hard]?.scheduledDays ?? 0
        let good = preview[.good]?.scheduledDays ?? 0
        let easy = preview[.easy]?.scheduledDays ?? 0
        #expect(hard >= 1)
        #expect(hard < good)
        #expect(good < easy)
        #expect(good > learned.scheduledDays)
        #expect(preview[.again]?.memory.state == .relearning)
        #expect(preview[.again]?.memory.lapses == 1)
    }

    @Test func difficultyStaysInRange() {
        var memory = newCard
        var time = now
        for _ in 0..<20 {
            memory = scheduler.next(memory, rating: .again, now: time).memory
            time = time.addingTimeInterval(3600)
        }
        #expect(memory.difficulty <= 10)
        #expect(memory.difficulty >= 1)
        #expect(memory.stability > 0)
    }
}

struct QuizTests {
    private func quizEntries() throws -> [LibraryEntry] {
        let level = #"{"version":2,"words":[{"word":"abandon","meanings":[{"pos":"v.","zh":"放棄","examples":[{"en":"They abandoned the plan.","zh":"他們放棄了計畫。"}]}]}]}"#
        let quiz = #"""
        {"version":1,"words":[],"sentences":[
          {"id":"abandon-01","target":"abandon","chinese":"放棄","pos":"v.","contextZh":"別＿＿夢想。","referenceEn":"Do not abandon your dream.",
           "accepted":["abandon","give up"],"contextEn":"The team had to ＿＿ its practice.","contextEnZh":"球隊只好放棄練習。","acceptedEn":["abandon"]},
          {"target":"nothing","accepted":"bad"}
        ]}
        """#
        return try PackParser.entries(files: [
            (name: "quiz-level4.json", data: Data(quiz.utf8)),
            (name: "level4.json", data: Data(level.utf8)),
        ])
    }

    @Test func quizItemsAttachToTheirWord() throws {
        let entries = try quizEntries()
        #expect(entries.map(\.id) == ["w:abandon"])
        let detail = try #require(entries[0].detail).decodedDetail()
        #expect(detail.quiz?.count == 1)
        #expect(detail.quiz?.first?.accepted == ["abandon", "give up"])
    }

    @Test func buildsQuestionsAndChecksAnswers() throws {
        let entries = try quizEntries()
        let detail = try #require(entries[0].detail).decodedDetail()
        let card = Card(id: "w:abandon", word: "abandon", pos: "v.", zh: "放棄")

        let zhToEn = try #require(QuizBuilder.question(kind: .zhToEn, card: card, detail: detail))
        #expect(zhToEn.prompt == "別＿＿夢想。")
        #expect(QuizBuilder.isCorrect("Abandon ", for: zhToEn))
        #expect(QuizBuilder.isCorrect("abandoned", for: zhToEn))
        #expect(QuizBuilder.isCorrect("give  up", for: zhToEn))
        #expect(!QuizBuilder.isCorrect("abandonment", for: zhToEn))
        #expect(zhToEn.letterHint == "a _ _ _ _ _ _")

        let cloze = try #require(QuizBuilder.question(kind: .cloze, card: card, detail: detail))
        #expect(cloze.prompt == "The team had to ＿＿ its practice.")
        #expect(!QuizBuilder.isCorrect("abandoned", for: cloze))

        // 沒有題目的字：用例句挖空，答案是句子裡的寫法
        var noQuiz = detail
        noQuiz.quiz = nil
        let fromExample = try #require(QuizBuilder.question(kind: .cloze, card: card, detail: noQuiz))
        #expect(fromExample.prompt == "They ＿＿ the plan.")
        #expect(fromExample.answers == ["abandoned"])
    }

    @Test func phraseClozeBlanksEachChunk() throws {
        let card = Card(id: "p:not only ... but also", word: "not only ... but also", zh: "不但…而且",
                        example: "She is not only smart but also kind.")
        let question = try #require(QuizBuilder.question(kind: .phrase, card: card, detail: nil))
        #expect(question.prompt == "She is ＿＿ smart ＿＿ kind.")
        #expect(question.answers == ["not only but also"])
        #expect(question.letterHint == "n _ _   o _ _ _   b _ _   a _ _ _")
    }
}

struct PatternTests {
    @Test func anchorsComeFromTheFormula() {
        #expect(Highlighter.anchors(fromPattern: "It is not until + 時間／子句 + that + S + V") == ["it is not until", "that"])
        #expect(Highlighter.anchors(fromPattern: "S + make it a rule to + V") == ["make it a rule to"])
    }

    @Test func anchorsMatchOtherTenses() throws {
        let highlighter = Highlighter(anchors: ["it is not until", "that"])
        let text = "It was not until the 1990s that the internet became popular."
        let regex = try #require(highlighter.regex)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        #expect(matches.map { (text as NSString).substring(with: $0.range) } == ["It was not until", "that"])
    }

    @MainActor
    @Test func importsPatternsIntoTheirOwnDeck() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Deck.self, Card.self, ReviewLog.self, CardContent.self, DeckLink.self, configurations: config)
        let context = ModelContext(container)
        let json = #"""
        [{"id":"1","deck_name":"第 3 課","word":"It is not until + 時間 + that + S + V","pos":null,"zh":"直到…才…",
          "example":"It was not until 1990 that it changed.","example_zh":"直到 1990 年才改變。","source":"library",
          "library_word_id":"pt:it is not until|that","kind":"pattern",
          "detail":{"pattern":"It is not until + 時間 + that + S + V","zh":"直到…才…","anchors":["it is not until","that"],
                    "slots":[{"slot":"時間","accepts":"時間名詞","examples":["1990"]}],"examples":[{"en":"It was not until 1990 that it changed."}]}},
         {"id":"2","deck_name":"第 3 課","word":"ability","pos":"n.","zh":"能力","example":null,"example_zh":null,
          "source":"library","library_word_id":"w:ability","detail":"壞掉的"}]
        """#
        let items = try JSONDecoder().decode([InboxItem].self, from: Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[1].detail == nil)

        let result = try InboxImporter.importItems(items, into: context)
        #expect(result.added == 2)
        #expect(result.patterns == 1)
        #expect(result.toastMessage == "從 Claude 匯入 1 個單字和 1 個句型到〈第 3 課〉")

        let decks = try context.fetch(FetchDescriptor<Deck>())
        #expect(decks.count == 2)
        #expect(Set(decks.map(\.category)) == [.word, .pattern])

        let detail = try #require(CardDetail.load(for: "pt:it is not until|that", in: context))
        #expect(detail.pattern?.slots.first?.slot == "時間")
        #expect(DetailTab.available(for: detail) == [.structure, .examples])

        // 再送一次同一個句型：不重複，內容更新
        let again = try InboxImporter.importItems([items[0]], into: context)
        #expect(again.added == 0)
        #expect(again.skipped == 1)
    }
}

@MainActor
struct HandoutTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Deck.self, Card.self, ReviewLog.self, CardContent.self, DeckLink.self, configurations: config)
        return ModelContext(container)
    }

    @Test func letterHintKeepsSbAndCapsLength() {
        #expect(HandoutHTML.letterHint("give up") == "g _ _ _   u _")
        #expect(HandoutHTML.letterHint("take care of sb") == "t _ _ _   c _ _ _   o _   sb")
        #expect(HandoutHTML.letterHint("internationalization").filter { $0 == "_" }.count == 9)
    }

    @Test func underlinesDifferentLetters() {
        let (a, b) = HandoutHTML.underlinedDifference("affect", "effect")
        #expect(a == "<u>a</u>ffect")
        #expect(b == "<u>e</u>ffect")
    }

    @Test func weakestRangeSkipsNewCardsAndPutsWeakFirst() throws {
        let context = try makeContext()
        let now = Date()
        let deck = Deck(id: "gsat-3", name: "學測 Level 3", kind: .storePack, level: 3)
        context.insert(deck)
        for (id, stability) in [("w:strong", 60.0), ("w:weak", 1.0), ("w:new", 0.0)] {
            let card = Card(id: id, word: String(id.dropFirst(2)), zh: "字")
            card.deck = deck
            if stability > 0 {
                card.state = .review
                card.stability = stability
                card.lastReview = now.addingTimeInterval(-5 * 86_400)
            }
            context.insert(card)
        }
        try context.save()

        let entries = try HandoutBuilder.entries(HandoutOptions(range: .weakest), context: context, now: now)
        #expect(entries.map(\.card.id) == ["w:weak", "w:strong"])
        #expect(entries.first?.levelText == "L3")
        #expect(entries.first?.memoryText.count == 5)
    }

    @Test func testSheetNeverPrintsTheAnswerInTheQuestion() throws {
        let context = try makeContext()
        let deck = Deck(id: "custom:x", name: "第 3 課", kind: .custom)
        context.insert(deck)
        let card = Card(id: "claude:1", word: "abandon", pos: "v.", zh: "放棄",
                        example: "They abandoned the plan after a week.", exampleZh: "他們一週後放棄了計畫。", source: .claude)
        card.deck = deck
        context.insert(card)
        try context.save()

        var options = HandoutOptions(kind: .test, range: .deck, deckID: "custom:x")
        let entries = try HandoutBuilder.entries(options, context: context)
        let html = HandoutHTML.document(entries: entries, options: options, rangeTitle: "第 3 課")
        // 答案只在右邊折起來的那一欄
        let key = try #require(html.firstRange(of: #/<div class="key[^"]*">[^<]*</div>/#))
        #expect(html[key].contains("abandon"))
        var question = html
        question.removeSubrange(key)
        #expect(!question.lowercased().contains("abandon"))
        #expect(question.contains("They \(HandoutHTML.blank) the plan"))
        #expect(question.contains("a _ _ _ _ _ _"))

        options.kind = .notes
        let notes = HandoutHTML.document(entries: entries, options: options, rangeTitle: "第 3 課")
        #expect(notes.contains("They <b>abandoned</b> the plan"))
        #expect(notes.contains("第 3 課 · 1 字"))

        // 速查表照熟悉度分組：還沒背過的是新字
        options.kind = .sheet
        let sheet = HandoutHTML.document(entries: entries, options: options, rangeTitle: "第 3 課")
        #expect(sheet.contains("新字<span>1 字</span>"))
        #expect(!sheet.contains("還不熟"))
    }
}
