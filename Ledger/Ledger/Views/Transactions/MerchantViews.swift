import SwiftUI
import SwiftData
import MapKit
import Charts
import UIKit

/// 詳情頁的小地圖：用商家名稱（或發票上的地址）在 Apple 地圖搜尋
/// 有 trailing（例如消費統計）時，地圖和它並排成兩個正方形；找不到位置就只顯示 trailing
struct MerchantMapCard<Trailing: View>: View {
    var merchant: String
    var address: String?
    /// 已經知道分店位置（捷徑附上位置比對出來的）就直接用，不用再搜尋
    var coordinate: CLLocationCoordinate2D? = nil
    var branch: String? = nil
    /// 參數：是不是跟地圖並排（正方形）
    var trailing: (Bool) -> Trailing

    @State private var item: MKMapItem?
    @State private var searched = false
    @State private var geoAddress: String?
    @Query private var visits: [Entry]

    init(merchant: String, address: String? = nil, coordinate: CLLocationCoordinate2D? = nil, branch: String? = nil,
         @ViewBuilder trailing: @escaping (Bool) -> Trailing) {
        self.merchant = merchant
        self.address = address
        self.coordinate = coordinate
        self.branch = branch
        self.trailing = trailing
        let m = merchant
        _visits = Query(filter: #Predicate<Entry> { $0.title == m })
    }

    private var paired: Bool { Trailing.self != EmptyView.self }

    var body: some View {
        Group {
            if paired {
                if let item {
                    HStack(spacing: 12) {
                        square { mapTile(item) }
                        square { trailing(true) }
                    }
                    .transition(.opacity)
                } else if searched {
                    // 找不到位置就不硬放地圖
                    trailing(false)
                } else {
                    HStack(spacing: 12) {
                        square {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(.regularMaterial)
                                .overlay(ProgressView())
                        }
                        square { trailing(true) }
                    }
                }
            } else if let item {
                square { mapTile(item) }
                    .frame(maxWidth: 280)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.snappy, value: item != nil)
        .animation(.snappy, value: searched)
        .task(id: (address ?? "") + merchant + (branch ?? "")) { await search() }
    }

    /// 固定 1:1，裡面的內容填滿
    private func square<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { content() }
    }

    /// 地圖鋪滿整塊，店名放在底部
    private func mapTile(_ item: MKMapItem) -> some View {
        Button {
            item.openInMaps()
        } label: {
            Map(initialPosition: .camera(MapCamera(centerCoordinate: item.location.coordinate,
                                                   distance: 650, heading: 0, pitch: 55)),
                interactionModes: []) {
                Marker(item.name ?? merchant, systemImage: "bag.fill", coordinate: item.location.coordinate)
                    .tint(Color.purple)
                MapCircle(center: item.location.coordinate, radius: 45)
                    .foregroundStyle(Color.purple.opacity(0.18))
                    .stroke(Color.purple.opacity(0.8), lineWidth: 1.5)
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    if let area = area(of: item) {
                        Text(area).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(item.name ?? merchant).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("去過 \(visits.count) 次").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial)
            }
            .clipShape(.rect(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .foregroundStyle(.primary)
        }
        .buttonStyle(ChipPressStyle())
    }

    /// 例如「彰化縣 彰化市」：從地址裡抓出縣市和鄉鎮區
    private func area(of item: MKMapItem) -> String? {
        for addr in [item.address?.fullAddress, geoAddress, address, item.address?.shortAddress] {
            if let addr, let a = BranchMatcher.area(in: addr) { return a }
        }
        return nil
    }

    private func search() async {
        if let coordinate {
            let it = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
            it.name = branch ?? merchant
            item = it
            searched = true
            // 自己建的地點沒有地址，反查一次才有縣市
            if let req = MKReverseGeocodingRequest(location: it.location),
               let hit = try? await req.mapItems.first {
                geoAddress = hit.address?.fullAddress
            }
            return
        }
        var tries: [String] = []
        let addr: String = address?.trimmingCharacters(in: .whitespaces) ?? ""
        if !addr.isEmpty { tries.append("\(merchant) \(addr)") }
        if addr.count >= 6 { tries.append(addr) }
        if let branch, !branch.isEmpty, branch != merchant { tries.append(branch) }
        tries.append(BranchMatcher.searchName(merchant))
        tries = tries.filter { $0.count >= 2 && $0 != "未命名" }
        var found: MKMapItem?
        for q in tries {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.resultTypes = [.pointOfInterest, .address]
            // 預設在台灣找
            req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.96),
                                            latitudinalMeters: 450_000, longitudinalMeters: 450_000)
            if let hit = try? await MKLocalSearch(request: req).start().mapItems.first {
                found = hit
                break
            }
        }
        item = found
        searched = true
    }
}

extension MerchantMapCard where Trailing == EmptyView {
    init(merchant: String, address: String? = nil, coordinate: CLLocationCoordinate2D? = nil, branch: String? = nil) {
        self.init(merchant: merchant, address: address, coordinate: coordinate, branch: branch) { _ in EmptyView() }
    }
}

/// 這筆交易是不是在某個實體地點發生的（回饋、利息、轉帳這類就不找地圖）
enum PlaceCheck {
    private static let nonPlaceWords = ["回饋", "利息", "退款", "退費", "退貨", "手續費", "年費", "轉帳", "轉入", "轉出",
                                        "繳費", "扣繳", "薪資", "薪水", "獎金", "紅利", "折抵", "提款",
                                        "銀行", "信用卡", "卡費", "保費", "訂閱", "會員", "月費", "內購"]

    static func hasPlace(title: String, kind: EntryKind, categoryName: String?) -> Bool {
        guard kind == .expense else { return false }
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != "未命名", !PayMethod.isPayMethod(t) else { return false }
        let text = t + " " + (categoryName ?? "")
        return !nonPlaceWords.contains { text.contains($0) }
    }
}

/// 在這個商家總共花了多少（收入就是總共收到多少）
struct MerchantSummaryCard: View {
    var merchant: String
    var currency: String
    var hidden: Bool
    var income = false
    /// 跟地圖並排的正方形版本
    var compact = false

    @Query private var entries: [Entry]

    init(merchant: String, currency: String, hidden: Bool, income: Bool = false, compact: Bool = false) {
        self.merchant = merchant
        self.currency = currency
        self.hidden = hidden
        self.income = income
        self.compact = compact
        let m = merchant
        // 連鎖店：不同寫法（全家／全家便利商店）都算同一家，所以抓全部再自己篩
        if BrandLogo.brand(for: merchant) != nil {
            _entries = Query(sort: \Entry.date, order: .reverse)
        } else {
            _entries = Query(filter: #Predicate<Entry> { $0.title == m }, sort: \Entry.date, order: .reverse)
        }
    }

    private var displayName: String { BrandLogo.brand(for: merchant)?.name ?? merchant }

    var body: some View {
        let kind: EntryKind = income ? .income : .expense
        let key = BrandLogo.groupKey(for: merchant)
        let list = entries.filter { $0.kind == kind && BrandLogo.groupKey(for: $0.title) == key }
        let total = list.reduce(0) { $0 + $1.amount }
        let month = DateText.monthInterval(.now)
        let thisMonth = list.filter { month.contains($0.date) }.reduce(0) { $0 + $1.amount }
        let totalTitle = income ? "總共收到" : "總共花了"
        NavigationLink {
            MerchantDetailView(merchant: merchant)
        } label: {
            if compact {
                compactBody(totalTitle: totalTitle, total: total, thisMonth: thisMonth, count: list.count)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        MerchantLogo(name: merchant, size: 28) {
                            Image(systemName: "storefront").font(.headline)
                        }
                        Text("在「\(displayName)」").font(.headline).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.forward").foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top) {
                        stat(totalTitle, total)
                        stat("本月", thisMonth)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("次數").font(.caption).foregroundStyle(.secondary)
                            Text("\(list.count) 次").font(.title3.weight(.semibold)).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .foregroundStyle(.primary)
                .cardStyle()
            }
        }
        .buttonStyle(.plain)
    }

    private func compactBody(totalTitle: String, total: Double, thisMonth: Double, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MerchantLogo(name: merchant, size: 34) {
                    Image(systemName: "storefront").foregroundStyle(.secondary)
                }
                Text(displayName).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(totalTitle).font(.caption).foregroundStyle(.secondary)
                MoneyText(value: total, currency: currency, hidden: hidden, font: .title2.weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            Spacer(minLength: 6)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本月").font(.caption).foregroundStyle(.secondary)
                    MoneyText(value: thisMonth, currency: currency, hidden: hidden, font: .subheadline.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("次數").font(.caption).foregroundStyle(.secondary)
                    Text("\(count) 次").font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.primary)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28, style: .continuous))
        .contentShape(.rect(cornerRadius: 28, style: .continuous))
    }

    private func stat(_ title: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            MoneyText(value: v, currency: currency, hidden: hidden, font: .title3.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// 單一商家（連鎖店會把各分店合在一起）的消費分析，可以切換看某一家分店
struct MerchantDetailView: View {
    var merchant: String
    @Query private var entries: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var opened: Entry?
    /// 空字串＝全部分店
    @State private var branch = ""

    private static let noBranch = "未標注"

    init(merchant: String) {
        self.merchant = merchant
        let m = merchant
        if BrandLogo.brand(for: merchant) != nil {
            _entries = Query(sort: \Entry.date, order: .reverse)
        } else {
            _entries = Query(filter: #Predicate<Entry> { $0.title == m }, sort: \Entry.date, order: .reverse)
        }
    }

    private struct BranchStat: Identifiable {
        var name: String
        var total: Double
        var count: Int
        var id: String { name }
    }

    private struct ItemStat: Identifiable {
        var name: String
        var total: Double
        var count: Double
        var id: String { name }
    }

    private var displayName: String { BrandLogo.brand(for: merchant)?.name ?? merchant }

    /// 只顯示分店名，不重複品牌名
    private func short(_ b: String) -> String {
        b == Self.noBranch ? b : BrandLogo.shortBranch(b, merchant: merchant)
    }

    private func branchName(_ e: Entry) -> String {
        let b = e.branch?.trimmingCharacters(in: .whitespaces) ?? ""
        // 只有品牌名、或只是地址的，都算「未標注」
        return BranchMatcher.isBrandOnly(b, merchant: e.title) ? Self.noBranch : b
    }

    var body: some View {
        let key = BrandLogo.groupKey(for: merchant)
        let mine: [Entry] = entries.filter { BrandLogo.groupKey(for: $0.title) == key }
        let branches = branchStats(mine)
        let shown: [Entry] = branch.isEmpty ? mine : mine.filter { branchName($0) == branch }
        let spent: [Entry] = shown.filter { $0.kind == .expense }
        let hasBranches = branches.contains { $0.name != Self.noBranch }

        List {
            Section {
                header(spent)
                if !spent.isEmpty {
                    monthChart(spent)
                }
            }
            if hasBranches {
                Section {
                    Picker("分店", selection: $branch) {
                        Text("全部分店").tag("")
                        ForEach(branches) { b in
                            Text(short(b.name)).tag(b.name)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if branch.isEmpty && branches.count > 1 {
                Section("各分店") {
                    let maxTotal = branches.map(\.total).max() ?? 1
                    ForEach(branches) { b in
                        Button {
                            withAnimation(.snappy) { branch = b.name }
                        } label: {
                            branchRow(b, maxTotal: maxTotal)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            let items = topItems(spent)
            if !items.isEmpty {
                Section("常買") {
                    ForEach(items) { it in
                        HStack {
                            Text(it.name).lineLimit(1)
                            Spacer()
                            Text("\(it.count.formatted(.number.precision(.fractionLength(0...1)))) 次")
                                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            Text(Money.format(it.total, hidden: hidden))
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                                .frame(minWidth: 64, alignment: .trailing)
                        }
                    }
                }
            }
            if !spent.isEmpty && PlaceCheck.hasPlace(title: merchant, kind: .expense, categoryName: spent.first?.category?.fullName) {
                Section {
                    mapCard(shown)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section(branch.isEmpty ? "紀錄" : "\(short(branch)) 的紀錄") {
                ForEach(shown) { e in
                    Button { opened = e } label: {
                        EntryRow(entry: e, hidden: hidden, showsDate: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .animation(.snappy, value: branch)
        .navigationTitle(branch.isEmpty ? displayName : short(branch))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $opened) { EntryDetailView(entry: $0) }
    }

    // MARK: 區塊

    private func header(_ spent: [Entry]) -> some View {
        let total = spent.reduce(0) { $0 + $1.amount }
        let avg = spent.isEmpty ? 0 : total / Double(spent.count)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("總共花了").foregroundStyle(.secondary)
                MoneyText(value: total, hidden: hidden, font: .system(size: 38, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("\(spent.count) 次・平均每次 \(Money.format(avg, hidden: hidden))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            MerchantLogo(name: merchant, size: 64)
        }
        .padding(.vertical, 4)
    }

    private func monthChart(_ spent: [Entry]) -> some View {
        // 最近 6 個月（沒花的月份補 0），用「10月」這種文字當橫軸，柱子固定寬度
        let cal = Calendar.current
        let thisMonth = DateText.monthInterval(.now).start
        let sums = Dictionary(grouping: spent) { DateText.monthInterval($0.date).start }
            .mapValues { $0.reduce(0) { $0 + $1.amount } }
        let byMonth: [(label: String, total: Double, current: Bool)] = (0..<6).reversed().compactMap { back in
            guard let m = cal.date(byAdding: .month, value: -back, to: thisMonth) else { return nil }
            return (DateText.month(m), sums[m] ?? 0, back == 0)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("最近 6 個月").font(.caption).foregroundStyle(.secondary)
            Chart(byMonth, id: \.label) { m in
                BarMark(x: .value("月份", m.label), y: .value("金額", m.total), width: .fixed(22))
                    .foregroundStyle(m.current ? Color.accentColor : Color.accentColor.opacity(0.35))
                    .cornerRadius(6)
                    .annotation(position: .top, spacing: 4) {
                        if m.total > 0 {
                            Text(Money.format(m.total, hidden: hidden))
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.caption2) }
            }
            .frame(height: 120)
        }
        .padding(.vertical, 6)
    }

    private func branchRow(_ b: BranchStat, maxTotal: Double) -> some View {
        let ratio: Double = maxTotal > 0 ? b.total / maxTotal : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(short(b.name)).lineLimit(1)
                Spacer()
                Text("\(b.count) 次").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Text(Money.format(b.total, hidden: hidden))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
            GeometryReader { g in
                Capsule().fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(6, g.size.width * ratio))
            }
            .frame(height: 5)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    /// 選了分店且知道位置就直接用；否則用名稱搜尋
    @ViewBuilder
    private func mapCard(_ shown: [Entry]) -> some View {
        if branch.isEmpty {
            MerchantMapCard(merchant: displayName)
        } else if let e = shown.first(where: { $0.latitude != nil && $0.longitude != nil }),
                  let lat = e.latitude, let lon = e.longitude {
            MerchantMapCard(merchant: displayName, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            branch: branch)
        } else if branch != Self.noBranch {
            MerchantMapCard(merchant: displayName, address: shown.compactMap(\.branchAddress).first, branch: branch)
        }
    }

    // MARK: 計算

    private func branchStats(_ mine: [Entry]) -> [BranchStat] {
        let spent = mine.filter { $0.kind == .expense }
        let groups = Dictionary(grouping: spent) { branchName($0) }
        let stats: [BranchStat] = groups.map { name, list in
            BranchStat(name: name, total: list.reduce(0) { $0 + $1.amount }, count: list.count)
        }
        return stats.sorted { $0.total > $1.total }
    }

    /// 發票上最常買的品項（前 5 名，折扣不算）
    private func topItems(_ spent: [Entry]) -> [ItemStat] {
        var sums: [String: (total: Double, count: Double)] = [:]
        for e in spent {
            guard let r = Receipt.from(e.receiptJSON) else { continue }
            for it in r.items where it.price > 0 {
                let name = it.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let old = sums[name] ?? (0, 0)
                sums[name] = (old.total + it.price, old.count + max(it.quantity, 1))
            }
        }
        let list: [ItemStat] = sums.map { ItemStat(name: $0.key, total: $0.value.total, count: $0.value.count) }
        return Array(list.sorted { $0.count == $1.count ? $0.total > $1.total : $0.count > $1.count }.prefix(5))
    }
}
