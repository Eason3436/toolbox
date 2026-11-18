import Foundation
import SwiftData
import SwiftUI
import UIKit
import WidgetKit

/// 桌面小工具：App 裝在 LiveContainer 裡，自己不能帶小工具，由 LiveContainer 的通用小工具來畫。
/// 這裡把「還有幾張要背」寫成 LCWidgetSnapshot（接下來 12 小時每小時一筆、加上明天一早），
/// 放到 LiveContainer 的 App Group，小工具時間到了自己換下一筆。不在 LiveContainer 裡就什麼都不做
enum HomeWidgetPublisher {
    @MainActor
    static func publish(context: ModelContext, now: Date = Date(), calendar: Calendar = .current) {
        guard let group = LiveContainerBridge.appGroupURL,
              let bundleID = Bundle.main.bundleIdentifier
        else { return }
        let snapshot = makeSnapshot(context: context, now: now, calendar: calendar)
        let folder = group.appendingPathComponent(LCWidgetSnapshot.folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try LCWidgetSnapshot.encoder.encode(snapshot)
            try data.write(to: folder.appendingPathComponent("\(bundleID).json"), options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // 小工具只是順便更新，失敗不影響 App
        }
    }

    @MainActor
    static func makeSnapshot(context: ModelContext, now: Date, calendar: Calendar = .current) -> LCWidgetSnapshot {
        let forecast = StudyForecast.load(context: context, now: now, calendar: calendar)
        let allLogs = (try? context.fetch(FetchDescriptor<ReviewLog>())) ?? []
        let streak = StatsCalculator.streak(allLogs, now: now, calendar: calendar)
        let doneToday = forecast.todayLogs.count

        return LCWidgetSnapshot(
            appName: "EnRecall",
            bundleName: LiveContainerBridge.bundleName,
            containerName: LiveContainerBridge.containerName,
            lcScheme: LiveContainerBridge.urlScheme,
            systemImage: "text.book.closed.fill",
            tintHex: tintHex(),
            updatedAt: now,
            entries: times(after: now, calendar: calendar).map { date in
                let sameDay = calendar.isDate(date, inSameDayAs: now)
                return entry(counts: forecast.counts(at: date, calendar: calendar), date: date,
                             done: sameDay ? doneToday : 0, streak: streak)
            }
        )
    }

    /// 現在、接下來 12 小時的整點、明天 00:00（新字額度重算）
    static func times(after now: Date, calendar: Calendar = .current) -> [Date] {
        var result = [now]
        if let hour = calendar.dateInterval(of: .hour, for: now)?.end {
            for offset in 0..<12 {
                if let date = calendar.date(byAdding: .hour, value: offset, to: hour) { result.append(date) }
            }
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            result.append(tomorrow)
        }
        return Array(Set(result)).sorted()
    }

    static func entry(counts: StudyCounts, date: Date, done: Int, streak: Int) -> LCWidgetSnapshot.Entry {
        let total = counts.total
        var details = ["連續 \(streak) 天"]
        if done > 0 { details.append("今天背了 \(done) 張") }
        return LCWidgetSnapshot.Entry(
            date: date,
            value: total.formatted(),
            caption: total == 0 ? "今天背完了" : "張要背",
            subtitle: "複習 \(counts.due) · 新字 \(counts.new)",
            details: details,
            progress: done + total == 0 ? 1 : Double(done) / Double(done + total)
        )
    }

    /// 小工具的強調色：App 現在的配色（淺色版）
    @MainActor
    private static func tintHex() -> String? {
        let color = UIColor(Color.er.primary).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return "#" + [red, green, blue].map { String(byte($0), radix: 16).leftPadded(to: 2) }.joined().uppercased()
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
