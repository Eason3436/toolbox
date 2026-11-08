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
    @State private var results: [MKMapItem] = []
    @State private var searching = false

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
                    if searching && results.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                    ForEach(results, id: \.self) { item in
                        Button {
                            let c = item.location.coordinate
                            apply(name: item.name ?? query, address: item.address?.fullAddress ?? item.address?.shortAddress,
                                  latitude: c.latitude, longitude: c.longitude)
                        } label: {
                            placeRow(title: item.name ?? "", subtitle: item.address?.shortAddress ?? item.address?.fullAddress,
                                     trailing: nil)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("在地圖搜尋")
                } footer: {
                    if !searching && results.isEmpty && !query.isEmpty {
                        Text("找不到「\(query)」，換個關鍵字試試，例如加上路名或地區")
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
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋分店，例如：彰化精誠")
            .task(id: query) {
                // 打字停一下再搜
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await search()
            }
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

    /// 搜「商家 + 關鍵字」；沒打字就列出附近（去過的分店附近，否則全台）的同名店
    private func search() async {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let base = merchantName
        let q: String
        if typed.isEmpty {
            q = base
        } else if base.isEmpty || typed.localizedCaseInsensitiveContains(base) {
            q = typed
        } else {
            q = "\(base) \(typed)"
        }
        guard q.count >= 2 else { results = []; return }
        searching = true
        defer { searching = false }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.resultTypes = [.pointOfInterest, .address]
        if let p = knownPlaces.first(where: { $0.latitude != nil }), let lat = p.latitude, let lon = p.longitude {
            req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                            latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        } else {
            req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.96),
                                            latitudinalMeters: 450_000, longitudinalMeters: 450_000)
        }
        var items = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        // 打了字卻沒結果，就只用打的字再找一次
        if items.isEmpty, !typed.isEmpty, q != typed {
            req.naturalLanguageQuery = typed
            items = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        }
        guard !Task.isCancelled else { return }
        results = Array(items.prefix(15))
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
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func toggle(_ id: UUID) {
        withAnimation(.snappy) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        }
    }

    private func branchText(_ e: Entry) -> String {
        guard let b = e.branch, !b.isEmpty else { return "未標分店" }
        return BrandLogo.shortBranch(b, merchant: e.title)
    }
}
