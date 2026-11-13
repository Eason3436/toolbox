import Foundation
import SwiftData
import SwiftUI

// MARK: - 預算

enum BudgetPeriod: String, CaseIterable, Identifiable, Codable {
    case weekly, monthly, yearly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .weekly: "每週"
        case .monthly: "每月"
        case .yearly: "每年"
        }
    }
    var component: Calendar.Component {
        switch self {
        case .weekly: .weekOfYear
        case .monthly: .month
        case .yearly: .year
        }
    }
}

@Model
final class Budget {
    var id: UUID = UUID()
    var name: String = ""
    var amount: Double = 0
    var periodRaw: String = BudgetPeriod.monthly.rawValue
    var colorHex: String = "#5E1F3C"
    var pinned: Bool = true
    var archived: Bool = false
    var order: Int = 0
    var createdAt: Date = Date.now
    var cashewID: String?

    /// 空的代表「全部支出分類」
    var categories: [Category]? = []

    init(name: String, amount: Double, period: BudgetPeriod = .monthly) {
        self.id = UUID()
        self.name = name
        self.amount = amount
        self.periodRaw = period.rawValue
        self.createdAt = .now
    }

    var period: BudgetPeriod {
        get { BudgetPeriod(rawValue: periodRaw) ?? .monthly }
        set { periodRaw = newValue.rawValue }
    }

    var color: Color { Color(hex: colorHex) }

    func interval(containing date: Date = .now) -> DateInterval {
        Calendar.current.dateInterval(of: period.component, for: date) ?? DateInterval(start: date, duration: 86400 * 30)
    }

    func interval(offset: Int) -> DateInterval {
        let d = Calendar.current.date(byAdding: period.component, value: offset, to: .now) ?? .now
        return interval(containing: d)
    }

    func includes(_ e: Entry) -> Bool {
        guard e.kind == .expense, !e.excludeFromBudget else { return false }
        let cats = categories ?? []
        if cats.isEmpty { return true }
        guard let c = e.category else { return false }
        return cats.contains { $0.id == c.id || $0.id == c.main.id }
    }

    func spent(in interval: DateInterval, entries: [Entry]) -> Double {
        entries.filter { interval.contains($0.date) && includes($0) }.reduce(0) { $0 + $1.amount }
    }
}

// MARK: - 儲蓄目標

@Model
final class Goal {
    var id: UUID = UUID()
    var name: String = ""
    var target: Double = 0
    var symbol: String = "star.fill"
    var colorHex: String = "#2D5DA0"
    var endDate: Date?
    var archived: Bool = false
    var order: Int = 0
    var createdAt: Date = Date.now
    var cashewID: String?

    @Relationship(deleteRule: .nullify, inverse: \Entry.goal)
    var entries: [Entry]? = []

    init(name: String, target: Double) {
        self.id = UUID()
        self.name = name
        self.target = target
        self.createdAt = .now
    }

    var color: Color { Color(hex: colorHex) }

    var saved: Double {
        (entries ?? []).reduce(0) { $0 + $1.amount }
    }

    var progress: Double { target > 0 ? min(saved / target, 1) : 0 }
}

// MARK: - 借出／借入

enum LoanDirection: String, CaseIterable, Identifiable, Codable {
    case lent, borrowed
    var id: String { rawValue }
    var label: String { self == .lent ? "借出" : "借入" }
    var verb: String { self == .lent ? "對方還我" : "我還對方" }
}

struct LoanRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var amount: Double
    var note: String = ""
}

@Model
final class Loan {
    var id: UUID = UUID()
    var person: String = ""
    var amount: Double = 0
    var directionRaw: String = LoanDirection.lent.rawValue
    var date: Date = Date.now
    var dueDate: Date?
    var note: String = ""
    var currency: String = "TWD"
    var recordsData: Data = Data()
    var closed: Bool = false
    var createdAt: Date = Date.now
    var cashewID: String?

    init(person: String, amount: Double, direction: LoanDirection) {
        self.id = UUID()
        self.person = person
        self.amount = amount
        self.directionRaw = direction.rawValue
        self.createdAt = .now
    }

    var direction: LoanDirection {
        get { LoanDirection(rawValue: directionRaw) ?? .lent }
        set { directionRaw = newValue.rawValue }
    }

    var records: [LoanRecord] {
        get { (try? JSONDecoder().decode([LoanRecord].self, from: recordsData)) ?? [] }
        set { recordsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var repaid: Double { records.reduce(0) { $0 + $1.amount } }
    var remaining: Double { max(amount - repaid, 0) }
}
