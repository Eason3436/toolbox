import SwiftUI
import SwiftData
import MapKit
import Charts

/// 詳情頁的小地圖：用商家名稱（或發票上的地址）在 Apple 地圖搜尋
struct MerchantMapCard: View {
    var merchant: String
    var address: String?

    @State private var item: MKMapItem?
    @State private var searched = false

    var body: some View {
        Group {
            if let item {
                Button {
                    item.openInMaps()
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Map(initialPosition: .region(MKCoordinateRegion(center: item.location.coordinate,
                                                                        latitudinalMeters: 600, longitudinalMeters: 600)),
                            interactionModes: []) {
                            Marker(item.name ?? merchant, systemImage: "bag.fill", coordinate: item.location.coordinate)
                                .tint(Color.accentColor)
                        }
                        .frame(height: 150)
                        .allowsHitTesting(false)
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? merchant).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if let addr = item.address?.shortAddress ?? item.address?.fullAddress {
                                    Text(addr).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                        .padding(14)
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.snappy, value: item != nil)
        .task(id: (address ?? "") + merchant) { await search() }
    }

    private func search() async {
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
        let byMonth = Dictionary(grouping: spent) { DateText.monthInterval($0.date).start }
            .map { (month: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.month < $1.month }
            .suffix(12)
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("總共花了").foregroundStyle(.secondary)
                    MoneyText(value: total, hidden: hidden, font: .system(size: 38, weight: .bold, design: .rounded))
                    Text("\(spent.count) 次・平均每次 \(Money.format(spent.isEmpty ? 0 : total / Double(spent.count), hidden: hidden))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if byMonth.count > 1 {
                    Chart(Array(byMonth), id: \.month) { m in
                        BarMark(x: .value("月份", m.month, unit: .month), y: .value("金額", m.total))
                            .foregroundStyle(Color.accentColor.gradient)
                            .cornerRadius(4)
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 140)
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
                        VStack(alignment: .leading, spacing: 2) {
                            EntryRow(entry: e, hidden: hidden)
                            Text(e.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 58)
                        }
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
