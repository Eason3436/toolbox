import Foundation
import SwiftData

struct BillOccurrence: Identifiable {
    var bill: Bill
    var due: Date
    var id: String { "\(bill.id)-\(Bill.key(for: due))" }
    var paid: Bool { bill.isPaid(due) }
}

@MainActor
enum BillService {
    static func occurrences(_ bills: [Bill], in interval: DateInterval) -> [BillOccurrence] {
        bills.filter(\.active)
            .flatMap { b in b.dueDates(in: interval).map { BillOccurrence(bill: b, due: $0) } }
            .sorted { $0.due < $1.due }
    }

    static func markPaid(_ occ: BillOccurrence, context: ModelContext) {
        let bill = occ.bill
        let key = Bill.key(for: occ.due)
        guard !bill.paidKeys.contains(key) else { return }
        bill.paidKeys.append(key)
        let payDate = min(Date.now, Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: occ.due) ?? occ.due)
        let entry = Entry(title: bill.name, amount: bill.amount, kind: .expense, date: payDate,
                          category: bill.category, account: bill.account,
                          note: bill.platform.isEmpty ? "" : "平台：\(bill.platform)", source: .bill)
        entry.bill = bill
        entry.billKey = key
        context.insert(entry)
        try? context.save()
    }

    static func markUnpaid(_ occ: BillOccurrence, context: ModelContext) {
        let bill = occ.bill
        let key = Bill.key(for: occ.due)
        bill.paidKeys.removeAll { $0 == key }
        for e in bill.payments ?? [] where e.billKey == key {
            context.delete(e)
        }
        try? context.save()
    }

    /// 自動扣繳：到期日已過、尚未標記的帳單自動記帳
    static func processAutoPay(context: ModelContext) {
        let bills = ((try? context.fetch(FetchDescriptor<Bill>())) ?? []).filter { $0.autoPay && $0.active }
        guard !bills.isEmpty else { return }
        let cal = Calendar.current
        let end = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: .now)!)
        for bill in bills {
            // 只回補最近 90 天，避免一次補太多
            let start = max(bill.createdAt.addingTimeInterval(-86400 * 31), cal.date(byAdding: .day, value: -90, to: .now)!)
            for due in bill.dueDates(in: DateInterval(start: start, end: end)) where !bill.isPaid(due) {
                markPaid(BillOccurrence(bill: bill, due: due), context: context)
            }
        }
    }
}
