import SwiftUI
import SwiftData

/// 設定 → 儲存空間：App 本身、資料庫、快取、暫存各佔多少
struct StorageView: View {
    @Environment(\.modelContext) private var context
    @State private var parts: [Part] = []
    @State private var loading = true
    @State private var entryCount = 0
    @State private var cleared: String?

    struct Part: Identifiable {
        var id: String
        var name: String
        var symbol: String
        var color: Color
        var bytes: Int64
        var note: String
    }

    var body: some View {
        let total: Int64 = parts.reduce(0) { $0 + $1.bytes }
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("總共").font(.caption).foregroundStyle(.secondary)
                    Text(loading ? "計算中…" : Self.format(total))
                        .font(.largeTitle.weight(.bold)).monospacedDigit()
                        .contentTransition(.numericText())
                    usageBar(total: total)
                }
                .padding(.vertical, 6)
            }

            Section {
                ForEach(parts) { p in
                    HStack(spacing: 12) {
                        Image(systemName: p.symbol)
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(p.color.gradient, in: .rect(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text(p.note).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Self.format(p.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("共 \(entryCount) 筆記帳紀錄。發票只存文字，不存照片。")
            }

            Section {
                Button {
                    Task { await clearCaches() }
                } label: {
                    Label("清除快取和暫存檔", systemImage: "trash")
                }
                .disabled(loading)
                if let cleared {
                    Text(cleared).font(.footnote).foregroundStyle(.green)
                }
            } footer: {
                Text("只會刪掉可以重新產生的檔案（商家圖片、匯出過的備份檔等），不會動到記帳資料。")
            }
        }
        .navigationTitle("儲存空間")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func usageBar(total: Int64) -> some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(parts) { p in
                    if p.bytes > 0 {
                        Rectangle().fill(p.color.gradient)
                            .frame(width: max(3, g.size.width * Double(p.bytes) / Double(max(total, 1))))
                    }
                }
                Spacer(minLength: 0)
            }
            .clipShape(.capsule)
        }
        .frame(height: 12)
        .background(Color.secondary.opacity(0.12), in: .capsule)
        .animation(.snappy, value: total)
    }

    // MARK: 計算

    private func refresh() async {
        loading = true
        entryCount = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? 0
        let result: [Part] = await Task.detached(priority: .userInitiated) { Self.measure() }.value
        withAnimation(.snappy) {
            parts = result
            loading = false
        }
    }

    private func clearCaches() async {
        let before: Int64 = parts.filter { $0.id == "cache" || $0.id == "tmp" }.reduce(0) { $0 + $1.bytes }
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let dirs: [URL] = [fm.urls(for: .cachesDirectory, in: .userDomainMask)[0], fm.temporaryDirectory]
            for d in dirs {
                for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: f)
                }
            }
        }.value
        URLCache.shared.removeAllCachedResponses()
        await refresh()
        let after: Int64 = parts.filter { $0.id == "cache" || $0.id == "tmp" }.reduce(0) { $0 + $1.bytes }
        cleared = "已清出 \(Self.format(max(before - after, 0)))"
    }

    nonisolated static func measure() -> [Part] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let support: URL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches: URL = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let tmp: URL = fm.temporaryDirectory
        let docs: URL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let app: Int64 = size(of: Bundle.main.bundleURL)
        let db: Int64 = size(of: support)
        let cache: Int64 = size(of: caches)
        let temp: Int64 = size(of: tmp)
        let doc: Int64 = size(of: docs)
        let all: Int64 = size(of: home)
        let other: Int64 = max(all - db - cache - temp - doc, 0)

        return [
            Part(id: "app", name: "App 本身", symbol: "app.fill", color: .gray, bytes: app, note: "安裝檔"),
            Part(id: "db", name: "記帳資料", symbol: "cylinder.split.1x2.fill", color: .blue, bytes: db, note: "交易、分類、帳戶、發票文字"),
            Part(id: "docs", name: "文件", symbol: "doc.fill", color: .teal, bytes: doc, note: "匯入的檔案"),
            Part(id: "cache", name: "快取", symbol: "photo.stack.fill", color: .orange, bytes: cache, note: "商家圖片、地圖等，可清除"),
            Part(id: "tmp", name: "暫存檔", symbol: "clock.arrow.circlepath", color: .yellow, bytes: temp, note: "匯出過的備份、CSV，可清除"),
            Part(id: "other", name: "其他", symbol: "ellipsis", color: .purple, bytes: other, note: "設定、系統記錄"),
        ]
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
