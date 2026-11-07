import SwiftUI
import SwiftData
import FoundationModels

@Generable(description: "依商家名稱選出的記帳分類")
struct AICategoryPick {
    @Guide(description: "從分類清單中選一個最適合這個商家的分類，必須完全照抄清單中的名稱")
    var category: String
}

/// 輸入商家名稱後自動挑分類：先看過去記過的同名商家，再問 Apple Intelligence
@MainActor
enum CategorySuggester {
    static func suggest(merchant: String, income: Bool, date: Date = .now) async -> (Category, fromAI: Bool)? {
        let name = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return nil }
        let pool = Store.categories(income: income)
        guard !pool.isEmpty else { return nil }

        if let learned = Learned.category(for: name, in: pool) { return (learned, false) }

        // 分類名稱本身出現在商家裡（例如「早餐店」→ 早餐）
        if let direct = pool.filter({ name.contains($0.name) }).max(by: { $0.name.count < $1.name.count }) {
            return (direct, false)
        }

        guard NoticeParser.aiAvailable else { return nil }
        let names = pool.map { $0.isSub ? "\($0.parent?.name ?? "")／\($0.name)" : $0.name }
        let session = LanguageModelSession(instructions: """
        你是記帳 App 的分類助理。使用者輸入一個商家或項目名稱，請從分類清單選出最適合的一個。
        例如：全家、7-11 買的多半是零食或餐飲；Uber、高鐵是交通；Netflix、Spotify、Apple 是訂閱；
        薪水、零用錢、獎金是收入。有子分類（格式「主分類／子分類」）而且符合時，優先選子分類。
        \(MealTime.hint)
        """)
        let prompt = "\(income ? "收入" : "支出")分類清單：\(names.joined(separator: "、"))\n\n商家或項目：\(name)\n付款時間：\(MealTime.describe(date))"
        guard let r = try? await session.respond(to: prompt, generating: AICategoryPick.self) else { return nil }
        let picked = r.content.category.trimmingCharacters(in: .whitespaces)
        if let i = names.firstIndex(of: picked) { return (pool[i], true) }
        let last = picked.split(separator: "／").last.map(String.init) ?? picked
        if let c = pool.first(where: { $0.name == last }) { return (c, true) }
        return nil
    }
}

/// 掛在分類膠囊上：商家名稱打完約 0.8 秒後自動選分類；使用者自己選過就不再動它
struct AutoCategoryModifier: ViewModifier {
    var merchant: String
    var income: Bool
    @Binding var selected: Category?
    var enabled: Bool = true
    var date: Date = .now

    @State private var autoPickedID: UUID?
    @State private var userPicked = false
    @State private var working = false
    @State private var lastSource: String?

    func body(content: Content) -> some View {
        VStack(spacing: 8) {
            content
            // 提示列固定佔一行高度，出現／消失時下面的按鈕不會被推來推去
            ZStack {
                if working {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Apple Intelligence 正在判斷分類…")
                    }
                    .transition(.blurReplace)
                } else if let lastSource, let c = selected, c.id == autoPickedID {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("\(lastSource)自動選了「\(c.name)」，點其他分類即可更改")
                    }
                    .transition(.blurReplace)
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(height: enabled ? 18 : 0)
        }
        .animation(.snappy, value: working)
        .animation(.snappy, value: autoPickedID)
        .onChange(of: selected?.id) { _, new in
            // 不是自動選的變動，就當作使用者自己選的
            if new != autoPickedID { userPicked = new != nil }
        }
        .task(id: "\(merchant)|\(income)|\(Calendar.current.component(.hour, from: date))") {
            guard enabled, !userPicked else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, !userPicked else { return }
            working = true
            let result = await CategorySuggester.suggest(merchant: merchant, income: income, date: date)
            working = false
            guard !Task.isCancelled, !userPicked, let r = result else { return }
            let c = r.0
            autoPickedID = c.id
            lastSource = r.fromAI ? "Apple Intelligence " : "依照以前的紀錄"
            withAnimation(.snappy) { selected = c }
        }
    }
}

extension View {
    func autoCategory(from merchant: String, income: Bool, selected: Binding<Category?>, enabled: Bool = true, date: Date = .now) -> some View {
        modifier(AutoCategoryModifier(merchant: merchant, income: income, selected: selected, enabled: enabled, date: date))
    }
}
