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

    /// 例如「彰化市」：從地址裡抓出縣市區
    private func area(of item: MKMapItem) -> String? {
        let addr = item.address?.fullAddress ?? item.address?.shortAddress ?? address ?? ""
        let t = addr.replacingOccurrences(of: "台灣", with: "").replacingOccurrences(of: "臺灣", with: "")
        if let r = t.range(of: #"[\p{Han}]{1,3}[市區鄉鎮]"#, options: .regularExpression) {
            return String(t[r])
        }
        return item.address?.shortAddress
    }

    private func search() async {
        if let coordinate {
            let it = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
            it.name = branch ?? merchant
            item = it
            searched = true
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
                                        "銀行", "信用卡", "卡費", "保費"]

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
        _entries = Query(filter: #Predicate<Entry> { $0.title == m }, sort: \Entry.date, order: .reverse)
    }

    var body: some View {
        let kind: EntryKind = income ? .income : .expense
        let list = entries.filter { $0.kind == kind }
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
                    HStack {
                        Label("在「\(merchant)」", systemImage: "storefront").font(.headline).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
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
            HStack(spacing: 6) {
                Image(systemName: "storefront").foregroundStyle(.secondary)
                Text(merchant).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
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

/// 單一商家的所有消費
struct MerchantDetailView: View {
    var merchant: String
    @Query private var entries: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var opened: Entry?

    init(merchant: String) {
        self.merchant = merchant
        let m = merchant
        _entries = Query(filter: #Predicate<Entry> { $0.title == m }, sort: \Entry.date, order: .reverse)
    }

    var body: some View {
        let spent = entries.filter { $0.kind == .expense }
        let total = spent.reduce(0) { $0 + $1.amount }
        // 最近 6 個月（沒花的月份補 0），用「10月」這種文字當橫軸，柱子固定寬度
        let cal = Calendar.current
        let thisMonth = DateText.monthInterval(.now).start
        let sums = Dictionary(grouping: spent) { DateText.monthInterval($0.date).start }
            .mapValues { $0.reduce(0) { $0 + $1.amount } }
        let byMonth: [(label: String, total: Double, current: Bool)] = (0..<6).reversed().compactMap { back in
            guard let m = cal.date(byAdding: .month, value: -back, to: thisMonth) else { return nil }
            return ("\(cal.component(.month, from: m))月", sums[m] ?? 0, back == 0)
        }
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("總共花了").foregroundStyle(.secondary)
                    MoneyText(value: total, hidden: hidden, font: .system(size: 38, weight: .bold, design: .rounded))
                    Text("\(spent.count) 次・平均每次 \(Money.format(spent.isEmpty ? 0 : total / Double(spent.count), hidden: hidden))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if !spent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
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
            }
            if !spent.isEmpty && PlaceCheck.hasPlace(title: merchant, kind: .expense, categoryName: spent.first?.category?.fullName) {
                Section {
                    MerchantMapCard(merchant: merchant)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section("紀錄") {
                ForEach(entries) { e in
                    Button { opened = e } label: {
                        EntryRow(entry: e, hidden: hidden, showsDate: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(merchant)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $opened) { EntryDetailView(entry: $0) }
    }
}
