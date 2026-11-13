import Foundation

/// 讀取 LiveContainer 捷徑版放進來的記帳請求。
/// 記帳裝在 LiveContainer 裡時，捷徑動作「記帳：從通知記帳／快速記一筆」由 LiveContainer 執行，
/// 它只能把 JSON 放進 Library/LCShortcutInbox/，記帳變成前景時再由這裡真正記帳。
/// 格式說明：toolbox repo 的 LiveContainer/README.md
enum LiveContainerInbox {
    private static var running = false

    static var folder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LCShortcutInbox", isDirectory: true)
    }

    private struct Item: Decodable {
        var action: String
        var text: String?
        var params: [String: Param]?
        var createdAt: String?
    }

    private enum Param: Decodable {
        case string(String), number(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .string(try c.decode(String.self)) }
        }
        var string: String? { if case .string(let s) = self { return s }; if case .number(let d) = self { return String(d) }; return nil }
        var number: Double? { if case .number(let d) = self { return d }; if case .string(let s) = self { return Double(s) }; return nil }
    }

    /// 處理收件匣，回傳每筆的結果文字（沒有東西時回傳空陣列）
    @MainActor
    static func process() async -> [String] {
        guard !running else { return [] }
        running = true
        defer { running = false }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }), !files.isEmpty else { return [] }

        let iso = ISO8601DateFormatter()
        var messages: [String] = []
        for file in files {
            defer { try? fm.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let item = try? JSONDecoder().decode(Item.self, from: data) else {
                messages.append("略過一筆看不懂的捷徑資料")
                continue
            }
            let date = item.createdAt.flatMap { iso.date(from: $0) } ?? .now
            let account = item.params?["accountName"]?.string
            do {
                switch item.action {
                case "ledger.logNotification":
                    guard let text = item.text, !text.isEmpty else { continue }
                    let r = try await NoticeRecorder.record(text: text, accountName: account, date: date)
                    messages.append(r.summary)
                case "ledger.quickAdd":
                    guard let merchant = item.params?["merchant"]?.string ?? item.text,
                          let amount = item.params?["amount"]?.number else { continue }
                    let r = try await NoticeRecorder.record(text: merchant, accountName: account,
                                                            merchantOverride: merchant, amountOverride: amount, date: date)
                    messages.append(r.summary)
                default:
                    messages.append("不認得的捷徑動作：\(item.action)")
                }
            } catch {
                messages.append("記帳失敗：\(error.localizedDescription)")
            }
        }
        return messages
    }
}
