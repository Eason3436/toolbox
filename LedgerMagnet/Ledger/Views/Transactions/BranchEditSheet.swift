import SwiftUI
import SwiftData
import MapKit

/// 一次改好幾筆交易的商家地點（分店）：從去過的分店挑，或用 Apple 地圖搜尋
struct BranchEditSheet: View {
    var entries: [Entry]
    var onDone: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Entry.date, order: .reverse) private var all: [Entry]

    @State private var query = ""
    /// 沒打字時列出的附近同名店
    @State private var nearby: [MKMapItem] = []
    @State private var completer = PlaceCompleter()
    @State private var resolving = false
    @FocusState private var fieldFocused: Bool

    private struct Place: Identifiable {
        var name: String
        var address: String?
        var latitude: Double?
        var longitude: Double?
        var count: Int
        var id: String { name }
    }

    /// 這幾筆交易的商家（連鎖店會合在一起）
    private var merchantKeys: Set<String> { Set(entries.map { BrandLogo.groupKey(for: $0.title) }) }

    private var merchantName: String {
        guard let t = entries.first?.title else { return "" }
        return BrandLogo.brand(for: t)?.name ?? BranchMatcher.searchName(t)
    }

    /// 同商家去過的分店，常去的在前面
    private var knownPlaces: [Place] {
        let keys = merchantKeys
        var byName: [String: Place] = [:]
        for e in all where keys.contains(BrandLogo.groupKey(for: e.title)) {
            guard let b = e.branch?.trimmingCharacters(in: .whitespaces), !b.isEmpty else { continue }
            var p = byName[b] ?? Place(name: b, address: nil, latitude: nil, longitude: nil, count: 0)
            p.count += 1
            if p.address == nil { p.address = e.branchAddress }
            if p.latitude == nil, let lat = e.latitude, let lon = e.longitude {
                p.latitude = lat
                p.longitude = lon
            }
            byName[b] = p
        }
        return byName.values.sorted { $0.count > $1.count }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        MerchantLogo(name: entries.first?.title ?? "", size: 36) {
                            Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(Color.accentColor)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(merchantName.isEmpty ? "更改地點" : merchantName).font(.headline)
                            Text("\(entries.count) 筆交易").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }

                let places = knownPlaces
                if !places.isEmpty {
                    Section("去過的分店") {
                        ForEach(places) { p in
                            Button {
                                apply(name: p.name, address: p.address, latitude: p.latitude, longitude: p.longitude)
                            } label: {
                                placeRow(title: displayName(p.name), subtitle: p.address, trailing: "\(p.count) 次")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜尋分店、路名或地區，例如：彰化精誠", text: $query)
                            .focused($fieldFocused)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    let typed = query.trimmingCharacters(in: .whitespaces)
                    if typed.isEmpty {
                        ForEach(nearby, id: \.self) { item in
                            Button { use(item) } label: {
                                placeRow(title: item.name ?? "", subtitle: item.address?.shortAddress ?? item.address?.fullAddress,
                                         trailing: nil)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        if resolving || (completer.searching && completer.results.isEmpty) {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        }
                        ForEach(completer.results, id: \.self) { c in
                            Button { use(c) } label: {
                                placeRow(title: c.title, subtitle: c.subtitle, trailing: nil)
                            }
                            .buttonStyle(.plain)
                            .disabled(resolving)
                        }
                        // 地圖找不到時，也可以直接用打的名稱
                        Button {
                            apply(name: typed, address: nil, latitude: nil, longitude: nil)
                        } label: {
                            Label("直接用「\(typed)」當分店名", systemImage: "character.cursor.ibeam")
                        }
                    }
                } header: {
                    Text("在地圖搜尋")
                } footer: {
                    if !query.isEmpty && !completer.searching && completer.results.isEmpty {
                        Text("地圖上找不到，換個關鍵字試試，例如只打路名或地區")
                    }
                }

                if entries.contains(where: { $0.branch != nil || $0.latitude != nil }) {
                    Section {
                        Button("清除地點", role: .destructive) {
                            apply(name: nil, address: nil, latitude: nil, longitude: nil)
                        }
                    }
                }
            }
            .navigationTitle("更改地點")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: query, initial: true) { _, q in
                completer.update(typed: q, brand: merchantName, region: searchRegion)
            }
            .task { await loadNearby() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
            }
        }
    }

    private func displayName(_ branch: String) -> String {
        BrandLogo.shortBranch(branch, merchant: entries.first?.title ?? "")
    }

    private func placeRow(title: String, subtitle: String?, trailing: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .contentShape(.rect)
    }

    /// 搜尋範圍：去過的分店附近，否則全台
    private var searchRegion: MKCoordinateRegion {
        if let p = knownPlaces.first(where: { $0.latitude != nil }), let lat = p.latitude, let lon = p.longitude {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                      latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.96),
                                  latitudinalMeters: 450_000, longitudinalMeters: 450_000)
    }

    /// 沒打字時：列出附近的同名店
    private func loadNearby() async {
        let base = merchantName
        guard base.count >= 2 else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = base
        req.resultTypes = [.pointOfInterest]
        req.region = searchRegion
        let items = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        nearby = Array(items.prefix(15))
    }

    private func use(_ item: MKMapItem) {
        let c = item.location.coordinate
        apply(name: item.name ?? query, address: item.address?.fullAddress ?? item.address?.shortAddress,
              latitude: c.latitude, longitude: c.longitude)
    }

    /// 點了自動完成的結果：換成地圖上的那個地點
    private func use(_ c: MKLocalSearchCompletion) {
        resolving = true
        Task {
            defer { resolving = false }
            let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: c)).start().mapItems.first
            if let item {
                use(item)
            } else {
                // 解析不到座標就只存名稱
                apply(name: c.title, address: c.subtitle.isEmpty ? nil : c.subtitle, latitude: nil, longitude: nil)
            }
        }
    }

    private func apply(name: String?, address: String?, latitude: Double?, longitude: Double?) {
        for e in entries {
            e.branch = name
            e.branchAddress = address
            e.latitude = latitude
            e.longitude = longitude
        }
        try? context.save()
        // 地圖上只有品牌名（例如「全家」）時，用位置找出分店名
        if let lat = latitude, let lon = longitude, let first = entries.first,
           BranchMatcher.isBrandOnly(name, merchant: first.title) {
            let list = entries
            Task {
                if let m = await BranchMatcher.nameBranch(merchant: first.title,
                                                           near: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                    for e in list { e.branch = m.name; if e.branchAddress == nil { e.branchAddress = m.address } }
                    try? context.save()
                }
            }
        }
        onDone()
        dismiss()
    }
}

/// 邊打字邊列出地圖上的地點（自動完成比每次打字都完整搜尋快，也不容易被限制次數）
@MainActor @Observable
final class PlaceCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    var searching = false

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var typed = ""
    @ObservationIgnored private var withBrand = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    /// 先搜「品牌＋打的字」，沒結果再只搜打的字
    func update(typed raw: String, brand: String, region: MKCoordinateRegion) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        typed = t
        guard !t.isEmpty else {
            completer.cancel()
            results = []
            searching = false
            return
        }
        completer.region = region
        withBrand = !brand.isEmpty && !t.localizedCaseInsensitiveContains(brand)
        searching = true
        completer.queryFragment = withBrand ? "\(brand) \(t)" : t
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let list = completer.results
        MainActor.assumeIsolated {
            if list.isEmpty && withBrand {
                withBrand = false
                self.completer.queryFragment = typed
                return
            }
            results = Array(list.prefix(15))
            searching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if withBrand {
                withBrand = false
                self.completer.queryFragment = typed
                return
            }
            results = []
            searching = false
        }
    }
}

/// 多選模式下每一列前面的圓圈
struct SelectionMark: View {
    var selected: Bool
    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// 多選時浮在底部的動作列
struct SelectionBar: View {
    var count: Int
    var action: () -> Void

    var body: some View {
        HStack {
            Text(count == 0 ? "選取交易" : "已選 \(count) 筆")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button("更改地點", systemImage: "mappin.and.ellipse", action: action)
                .buttonStyle(.glassProminent)
                .disabled(count == 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal)
        .padding(.bottom, 6)
    }
}

/// 設定 → 交易地點：多選交易，一次改成同一家分店
struct BranchBatchView: View {
    @Query(sort: \Entry.date, order: .reverse) private var all: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false

    @State private var selected: Set<UUID> = []
    @State private var unmarkedOnly = false
    @State private var search = ""
    @State private var editing = false

    private struct MerchantGroup: Identifiable {
        var key: String
        var name: String
        var entries: [Entry]
        var id: String { key }
    }

    /// 依商家分組（連鎖店合在一起），最近有消費的在前面
    private var groups: [MerchantGroup] {
        let list = all.filter { e in
            e.kind == .expense
                && !e.title.trimmingCharacters(in: .whitespaces).isEmpty
                && (!unmarkedOnly || (e.branch ?? "").isEmpty)
                && (search.isEmpty || e.title.localizedCaseInsensitiveContains(search)
                    || (e.branch?.localizedCaseInsensitiveContains(search) ?? false)
                    || (BrandLogo.brand(for: e.title)?.name.localizedCaseInsensitiveContains(search) ?? false))
        }
        var order: [String] = []
        var byKey: [String: [Entry]] = [:]
        for e in list {
            let k = BrandLogo.groupKey(for: e.title)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(e)
        }
        return order.map { k in
            let first = byKey[k]![0]
            return MerchantGroup(key: k, name: BrandLogo.brand(for: first.title)?.name ?? first.title, entries: byKey[k]!)
        }
    }

    var body: some View {
        let gs = groups
        List {
            Section {
                Toggle("只看還沒標分店的", isOn: $unmarkedOnly.animation(.snappy))
            } footer: {
                Text("勾選要改的交易，按下面的「更改地點」，可以從去過的分店挑，或在地圖搜尋。")
            }
            if gs.isEmpty {
                Section {
                    Text(search.isEmpty ? "沒有交易" : "沒有符合「\(search)」的交易").foregroundStyle(.secondary)
                }
            }
            ForEach(gs) { g in
                Section {
                    ForEach(g.entries) { e in
                        Button {
                            toggle(e.id)
                        } label: {
                            HStack(spacing: 12) {
                                SelectionMark(selected: selected.contains(e.id))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.date.formatted(.dateTime.month().day().hour().minute()))
                                        .font(.subheadline)
                                    Text(branchText(e)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Text(Money.format(e.amount, hidden: hidden)).monospacedDigit()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack(spacing: 8) {
                        MerchantLogo(name: g.entries[0].title, size: 22) {
                            Image(systemName: "storefront")
                        }
                        Text(g.name).lineLimit(1)
                        Spacer()
                        let ids = Set(g.entries.map(\.id))
                        Button(ids.isSubset(of: selected) ? "取消全選" : "全選") {
                            withAnimation(.snappy) {
                                if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
                            }
                        }
                        .font(.subheadline)
                        .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("交易地點")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜尋商家或分店")
        .toolbar {
            if !selected.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清除選取") { withAnimation(.snappy) { selected = [] } }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            SelectionBar(count: selected.count) { editing = true }
        }
        .sheet(isPresented: $editing) {
            BranchEditSheet(entries: all.filter { selected.contains($0.id) }) {
                selected = []
            }
        }
        .selectionHaptic(trigger: selected)
    }

    private func toggle(_ id: UUID) {
        withAnimation(.snappy) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        }
    }

    private func branchText(_ e: Entry) -> String {
        guard let b = e.branch, !BranchMatcher.isBrandOnly(b, merchant: e.title) else { return "未標注" }
        return BrandLogo.shortBranch(b, merchant: e.title)
    }
}
