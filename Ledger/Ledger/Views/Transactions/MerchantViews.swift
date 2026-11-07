import SwiftUI
import SwiftData
import MapKit
import Charts

/// 詳情頁的小地圖：用商家名稱（或發票上的地址）在 Apple 地圖搜尋
struct MerchantMapCard: View {
    var merchant: String
    var address: String?
    /// 已經知道分店位置（捷徑附上位置比對出來的）就直接用，不用再搜尋
    var coordinate: CLLocationCoordinate2D? = nil
    var branch: String? = nil

    @State private var item: MKMapItem?
    @State private var searched = false
    @Query private var visits: [Entry]

    init(merchant: String, address: String? = nil, coordinate: CLLocationCoordinate2D? = nil, branch: String? = nil) {
        self.merchant = merchant
        self.address = address
        self.coordinate = coordinate
        self.branch = branch
        let m = merchant
        _visits = Query(filter: #Predicate<Entry> { $0.title == m })
    }

    var body: some View {
        Group {
            if let item {
                Button {
                    item.openInMaps()
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        // 地區、店名、去過幾次
                        VStack(alignment: .leading, spacing: 2) {
                            if let area = area(of: item) {
                                Text(area).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text(item.name ?? merchant).font(.headline).lineLimit(1)
                            Text("\(visits.count)×").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)

                        // 立體小地圖
                        Map(initialPosition: .camera(MapCamera(centerCoordinate: item.location.coordinate,
                                                               distance: 650, heading: 0, pitch: 55)),
                            interactionModes: []) {
                            Marker(item.name ?? merchant, systemImage: "bag.fill", coordinate: item.location.coordinate)
                                .tint(Color.purple)
                            MapCircle(center: item.location.coordinate, radius: 45)
                                .foregroundStyle(Color.purple.opacity(0.18))
                                .stroke(Color.purple.opacity(0.8), lineWidth: 1.5)
                        }
                        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .all))
                        .frame(height: 130)
                        .clipShape(.rect(cornerRadius: 16, style: .continuous))
                        .allowsHitTesting(false)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.15)))
                    .foregroundStyle(.primary)
                }
                .buttonStyle(ChipPressStyle())
                .frame(maxWidth: 340)
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.snappy, value: item != nil)
        .task(id: (address ?? "") + merchant + (branch ?? "")) { await search() }
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
        let query = (address?.isEmpty == false ? "\(merchant) \(address!)" : merchant).trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, query != "未命名" else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.resultTypes = [.pointOfInterest, .address]
        // 預設在台灣找
        req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.96),
                                        latitudinalMeters: 450_000, longitudinalMeters: 450_000)
        item = try? await MKLocalSearch(request: req).start().mapItems.first
        searched = true
    }
}

/// 在這個商家總共花了多少
struct MerchantSummaryCard: View {
    var merchant: String
    var currency: String
    var hidden: Bool

    @Query private var entries: [Entry]

    init(merchant: String, currency: String, hidden: Bool) {
        self.merchant = merchant
        self.currency = currency
        self.hidden = hidden
        let m = merchant
        _entries = Query(filter: #Predicate<Entry> { $0.title == m }, sort: \Entry.date, order: .reverse)
    }

    var body: some View {
        let spent = entries.filter { $0.kind == .expense }
        let total = spent.reduce(0) { $0 + $1.amount }
        let month = DateText.monthInterval(.now)
        let thisMonth = spent.filter { month.contains($0.date) }.reduce(0) { $0 + $1.amount }
        NavigationLink {
            MerchantDetailView(merchant: merchant)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("在「\(merchant)」", systemImage: "storefront").font(.headline).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    stat("總共花了", total)
                    stat("本月", thisMonth)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("次數").font(.caption).foregroundStyle(.secondary)
                        Text("\(spent.count) 次").font(.title3.weight(.semibold)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(.primary)
            .cardStyle()
        }
        .buttonStyle(.plain)
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
            Section {
                MerchantMapCard(merchant: merchant)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
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
