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
        let container = try ModelContainer(for: Deck.self, Card.self, ReviewLog.self, configurations: config)
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
        let container = try ModelContainer(for: Deck.self, Card.self, ReviewLog.self, configurations: config)
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

        let result = try InboxImporter.importItems([item("ability", libraryID: "w:ability")], into: context)
        #expect(result.added == 0)
        #expect(result.skipped == 1)
        #expect(card.reps == 5)
        #expect(card.deck?.id == "gsat-1")
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
    }
}

@MainActor
struct PackInstallerTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Deck.self, Card.self, ReviewLog.self, configurations: config)
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
