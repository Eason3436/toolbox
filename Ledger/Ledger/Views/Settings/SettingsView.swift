import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.order) private var accounts: [Account]
    @AppStorage(Prefs.mainCurrencyKey) private var mainCurrency = "TWD"
    @AppStorage(Prefs.defaultAccountKey) private var defaultID = ""

    @State private var importing = false
    @State private var restoring = false
    @State private var exportURL: URL?
    @State private var csvURL: URL?
    @AppStorage("lockEnabled") private var lockEnabled = false
    @AppStorage(Haptics.enabledKey) private var hapticsEnabled = true
    @State private var importResult: String?
    @State private var importError: String?
    @State private var deletingAccount: Account?
    @State private var editingAccount: Account?
    @State private var addingAccount = false
    @State private var pickingSyncFolder = false
    @State private var syncStatus: String? = UserDefaults.standard.string(forKey: CloudSync.lastResultKey)
    @State private var syncFolder: String? = CloudSync.folderName
    @State private var showGuide = false

    var body: some View {
        NavigationStack {
            Form {
                // 最上面：設定自動記帳的大卡片
                Section {
                    SettingsHeroCard(title: "自動記帳", subtitle: "讓銀行通知自己記一筆") { showGuide = true }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    Picker(selection: $defaultID) {
                        Text("第一個帳戶").tag("")
                        ForEach(accounts.filter { !$0.archived }) { Text($0.name).tag($0.id.uuidString) }
                    } label: {
                        Label("捷徑預設帳戶", systemImage: "creditcard")
                    }
                    LabeledContent {
                        Text(NoticeParser.aiStatusText)
                    } label: {
                        Label("裝置端模型", systemImage: "cpu")
                    }
                }
                .settingsRow()

                Section {
                    NavigationLink { HapticsSettingsView() } label: {
                        LabeledContent {
                            Text(hapticsEnabled ? "開啟" : "關閉")
                        } label: {
                            Label("觸覺回饋", systemImage: "water.waves")
                        }
                    }
                    Toggle(isOn: $lockEnabled) {
                        Label("Face ID 鎖定", systemImage: "faceid")
                    }
                    Picker(selection: $mainCurrency) {
                        ForEach(Money.commonCurrencies, id: \.self) { Text($0).tag($0) }
                    } label: {
                        Label("主要幣別", systemImage: "banknote")
                    }
                    NavigationLink { HomeLayoutView() } label: {
                        Label("自訂主頁", systemImage: "square.grid.2x2")
                    }
                } header: {
                    SettingsHeader("一般")
                } footer: {
                    Text("Face ID 鎖定：離開 App 後再回來需要解鎖。資產總額與帳單合計會換算成主要幣別。")
                }
                .settingsRow()

                Section {
                    ThemePicker()
                        .padding(.vertical, 8)
                } header: {
                    SettingsHeader("主要色")
                }
                .settingsRow()

                Section {
                    ForEach(accounts) { a in
                        Button { editingAccount = a } label: {
                            HStack(spacing: 14) {
                                Circle().fill(a.color)
                                    .frame(width: 12, height: 12)
                                    .frame(width: 36, height: 36)
                                    .background(a.color.opacity(0.12), in: .rect(cornerRadius: 11, style: .continuous))
                                Text(a.name).foregroundStyle(a.archived ? .secondary : .primary)
                                if a.archived { Text("已封存").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Text(Money.format(a.balance, currency: a.currency)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .alignmentGuide(.listRowSeparatorLeading) { _ in -40 }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("刪除", systemImage: "trash") { deletingAccount = a }.tint(.red)
                        }
                    }
                    .onMove { from, to in
                        var list = accounts
                        list.move(fromOffsets: from, toOffset: to)
                        for (i, a) in list.enumerated() { a.order = i }
                        try? context.save()
                    }
                    Button { addingAccount = true } label: {
                        Label("新增帳戶", systemImage: "plus")
                    }
                } header: {
                    SettingsHeader("帳戶")
                }
                .settingsRow()

                Section {
                    NavigationLink { CategoryManagerView() } label: {
                        Label("管理分類", systemImage: "tag")
                    }
                    NavigationLink { BranchBatchView() } label: {
                        Label("交易地點", systemImage: "mappin.and.ellipse")
                    }
                    NavigationLink { ReceiptBatchView() } label: {
                        Label("匯入發票照片", systemImage: "doc.text.viewfinder")
                    }
                } header: {
                    SettingsHeader("分類、地點與發票")
                }
                .settingsRow()

                Section {
                    if let syncFolder {
                        LabeledContent {
                            Text(syncFolder)
                        } label: {
                            Label("資料夾", systemImage: "folder")
                        }
                        Button {
                            syncStatus = CloudSync.run(force: true)
                        } label: {
                            Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button("關閉同步", role: .destructive) {
                            CloudSync.turnOff()
                            self.syncFolder = nil
                            syncStatus = nil
                        }
                    } else {
                        Button {
                            // 跟匯入共用同一個檔案選擇器（同一頁放兩個 fileImporter 只有一個會動）
                            restoring = false
                            pickingSyncFolder = true
                            importing = true
                        } label: {
                            Label("選擇 iCloud 雲碟資料夾", systemImage: "icloud")
                        }
                    }
                    if let syncStatus {
                        Text(syncStatus + (CloudSync.lastSync.map { "・" + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now) } ?? ""))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    SettingsHeader("iCloud 同步")
                } footer: {
                    Text("在「檔案」裡選 iCloud 雲碟的一個資料夾（例如新建「記帳」）。每次打開 App 會自動合併其他裝置的資料，並每天留一份備份（保留 14 天）。")
                }
                .settingsRow()

                Section {
                    Button {
                        exportURL = try? Backup.export()
                    } label: {
                        Label("匯出完整備份（JSON）", systemImage: "externaldrive")
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("分享備份檔", systemImage: "square.and.arrow.up") }
                    }
                    Button {
                        restoring = true
                        pickingSyncFolder = false
                        importing = true
                    } label: {
                        Label("從備份還原", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        csvURL = try? Backup.exportCSV()
                    } label: {
                        Label("匯出交易 CSV", systemImage: "tablecells")
                    }
                    if let csvURL {
                        ShareLink(item: csvURL) { Label("分享 CSV", systemImage: "square.and.arrow.up") }
                    }
                    Button {
                        restoring = false
                        pickingSyncFolder = false
                        importing = true
                    } label: {
                        Label("從 Cashew 備份匯入", systemImage: "square.and.arrow.down")
                    }
                    if let importResult {
                        Text(importResult).font(.footnote).foregroundStyle(.green)
                    }
                    if let importError {
                        Text(importError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    SettingsHeader("備份與搬家")
                } footer: {
                    Text("還原會把備份合併進來，不會刪除現有資料。Cashew：在 Cashew 的「設定 → 備份 → 匯出資料」存成 .sql 檔再選取，重複匯入不會重複新增。")
                }
                .settingsRow()

                Section {
                    NavigationLink { ChangelogView() } label: {
                        LabeledContent {
                            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Changelog.current)
                        } label: {
                            Label("版本", systemImage: "info.circle")
                        }
                    }
                    NavigationLink { ContentView() } label: {
                        Label("數字動效示範", systemImage: "textformat.123")
                    }
                } header: {
                    SettingsHeader("關於")
                }
                .settingsRow()
            }
            .settingsStyle()
            .navigationDestination(isPresented: $showGuide) { ShortcutGuideView() }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: pickingSyncFolder ? [.folder] : (restoring ? [.json] : [.item])) { result in
                let isRestore = restoring
                if pickingSyncFolder {
                    pickingSyncFolder = false
                    importing = false
                    switch result {
                    case .success(let url):
                        do {
                            try CloudSync.setFolder(url)
                            syncFolder = CloudSync.folderName
                            syncStatus = CloudSync.run(force: true)
                        } catch {
                            syncStatus = "無法使用這個資料夾：\(error.localizedDescription)"
                        }
                    case .failure(let error):
                        syncStatus = "無法使用這個資料夾：\(error.localizedDescription)"
                    }
                    return
                }
                switch result {
                case .success(let url):
                    do {
                        if isRestore {
                            let n = try Backup.restore(from: url)
                            importResult = "已還原 \(n) 筆資料"
                        } else {
                            importResult = try CashewImporter.importBackup(at: url).text
                        }
                        importError = nil
                    } catch {
                        importError = error.localizedDescription
                        importResult = nil
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
                importing = false
                restoring = false
            }
            .sheet(item: $editingAccount) { AccountEditor(account: $0) }
            .accountDeleteDialog($deletingAccount)
            .sheet(isPresented: $addingAccount) { AccountEditor(account: nil) }
        }
    }

}

struct ShortcutGuideView: View {
    var body: some View {
        List {
            Section {
                step(1, "打開「捷徑」App，切到「自動化」，按右上角 ＋。")
                step(2, "選「通知」，App 選你的銀行（或信用卡、LINE Pay 等），可以再加條件：內文包含「消費」或「NT$」。")
                step(3, "選「立即執行」，關掉「執行時通知」。")
                step(4, "新增動作：搜尋「記帳」，選「從通知記帳」。")
                step(5, "點「通知內容」那格，選「捷徑輸入」→「通知」（整則通知會丟進來）。")
            } header: {
                Text("銀行 App 推播通知")
            } footer: {
                Text("之後每收到一次銀行通知，App 會在 iPhone 上拆出商家、金額與分類，自動記一筆。卡號末四碼對得上的話會記到那張卡，否則記到預設帳戶。")
            }

            Section {
                step(1, "自動化 ＋ →「訊息」，「訊息包含」填「消費」，寄件人選銀行簡訊號碼。")
                step(2, "動作選「從通知記帳」，「通知內容」選「捷徑輸入」。")
            } header: {
                Text("銀行簡訊")
            }

            Section {
                step(1, "自動化 ＋ →「錢包」，選你的卡片。")
                step(2, "動作選「快速記一筆」，商家選「商家」、金額選「金額」。")
            } header: {
                Text("Apple Pay 刷卡")
            }

            Section {
                Text("可以先在捷徑裡手動執行一次「從通知記帳」，確認你的銀行通知能正確辨識。")
                    .foregroundStyle(.secondary)
            } header: {
                Text("先測試")
            }
        }
        .navigationTitle("通知自動記帳")
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: .circle)
            Text(text)
        }
        .padding(.vertical, 2)
    }
}

struct CategoryManagerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.order) private var categories: [Category]
    @State private var showIncome = false
    @State private var editing: Category?
    @State private var adding = false

    var body: some View {
        List {
            Picker("", selection: $showIncome) {
                Text("支出").tag(false)
                Text("收入").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            let list = categories.filter { $0.isIncome == showIncome && !$0.isSub }.flatMap { [$0] + $0.sortedChildren }
            ForEach(list) { c in
                Button { editing = c } label: {
                    HStack(spacing: 12) {
                        if c.isSub { Spacer().frame(width: 24) }
                        c.icon(size: c.isSub ? 30 : 36)
                        Text(c.name)
                        Spacer()
                        Text("\(c.entries?.count ?? 0) 筆").foregroundStyle(.secondary).font(.footnote)
                    }
                }
                .buttonStyle(.plain)
            }
            .onMove { from, to in
                var l = list
                l.move(fromOffsets: from, toOffset: to)
                for (i, c) in l.enumerated() { c.order = i }
                try? context.save()
            }
            .onDelete { idx in
                for i in idx { Haptics.shared.trash(); context.delete(list[i]) }
                try? context.save()
            }
        }
        .navigationTitle("分類")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("新增", systemImage: "plus") { adding = true } }
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                withAnimation(.snappy) { CategoryStyle.applyAll(context: context) }
            } label: {
                Label("依名稱自動配圖示和顏色", systemImage: "wand.and.stars")
                    .font(.headline)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .padding(.bottom, 8)
        }
        .sheet(item: $editing) { CategoryEditor(category: $0, income: $0.isIncome) }
        .sheet(isPresented: $adding) { CategoryEditor(category: nil, income: showIncome) }
    }
}

struct CategoryEditor: View {
    var category: Category?
    var income: Bool
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.order) private var categories: [Category]

    @State private var name = ""
    @State private var symbol = "tag.fill"
    @State private var emoji = ""
    @State private var color = Color.orange
    @State private var parentID: UUID?

    private let symbols = ["fork.knife", "cup.and.saucer.fill", "cart.fill", "bag.fill", "basket.fill", "car.fill", "bus.fill", "tram.fill",
                           "airplane", "fuelpump.fill", "house.fill", "bolt.fill", "drop.fill", "wifi", "iphone", "tv.fill",
                           "gamecontroller.fill", "film.fill", "music.note", "book.fill", "graduationcap.fill", "stethoscope", "pills.fill", "cross.case.fill",
                           "dumbbell.fill", "tshirt.fill", "sparkles", "gift.fill", "pawprint.fill", "figure.2.and.child.holdinghands", "briefcase.fill", "doc.text.fill",
                           "arrow.triangle.2.circlepath", "banknote.fill", "chart.line.uptrend.xyaxis", "creditcard.fill", "heart.fill", "star.fill", "tag.fill", "square.grid.2x2.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        CategoryIcon(symbol: symbol, emoji: emoji.isEmpty ? nil : emoji, color: color, size: 72)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("名稱", text: $name)
                    TextField("表情符號（選填，會取代圖示）", text: $emoji)
                    ColorPicker("顏色", selection: $color, supportsOpacity: false)
                    Picker("主分類", selection: $parentID) {
                        Text("無（這是主分類）").tag(UUID?.none)
                        ForEach(categories.filter { $0.isIncome == income && !$0.isSub && $0.id != category?.id }) { c in
                            Text(c.name).tag(Optional(c.id))
                        }
                    }
                }
                Section("圖示") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(symbols, id: \.self) { s in
                            Image(systemName: s)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .foregroundStyle(symbol == s ? .white : color)
                                .background(symbol == s ? color : color.opacity(0.12), in: .rect(cornerRadius: 12))
                                .onTapGesture { symbol = s }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(category == nil ? "新增分類" : "編輯分類")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let category {
                    name = category.name
                    symbol = category.symbol
                    emoji = category.emoji ?? ""
                    color = category.color
                    parentID = category.parent?.id
                }
            }
        }
    }

    private func save() {
        let c = category ?? {
            let n = Category(name: name, symbol: symbol, colorHex: color.hexString, isIncome: income, order: (categories.map(\.order).max() ?? 0) + 1)
            context.insert(n)
            return n
        }()
        c.name = name.trimmingCharacters(in: .whitespaces)
        c.symbol = symbol
        c.emoji = emoji.isEmpty ? nil : String(emoji.prefix(2))
        c.colorHex = color.hexString
        if (c.children ?? []).isEmpty {
            c.parent = categories.first { $0.id == parentID && $0.id != c.id }
        }
        try? context.save()
        dismiss()
    }
}
