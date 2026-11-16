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
