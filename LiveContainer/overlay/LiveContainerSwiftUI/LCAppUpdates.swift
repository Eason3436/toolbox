//
//  LCAppUpdates.swift
//  LiveContainerSwiftUI
//
//  Added by Eason3436/toolbox: give each installed app a download link
//  (for example a GitHub Releases .ipa link). Every time LiveContainer comes
//  to the foreground it checks whether the file at that link is newer than
//  the installed copy, and offers a one-tap update that replaces the app
//  in place (data and settings are kept, like a normal replace install).
//

import SwiftUI

// MARK: - Checker

@MainActor
final class LCUpdateChecker: ObservableObject {
    static let shared = LCUpdateChecker()

    struct RemoteInfo {
        var date: Date
        var size: Int64?
    }

    /// bundle id -> download link
    @Published private(set) var links: [String: String] = [:]
    /// bundle id -> what the link currently points to
    @Published private(set) var remote: [String: RemoteInfo] = [:]
    /// bundle id -> last error while checking
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?

    private static let linksKey = "LCAppUpdateLinks"
    private static let disabledDefaultsKey = "LCAppUpdateDisabledDefaults"

    /// Apps built in Eason3436/toolbox get their link filled in automatically.
    static let defaultLinks: [String: String] = [
        "com.eason3436.toolbox": "https://github.com/Eason3436/toolbox/releases/download/latest/Toolbox.ipa",
        "com.eason3436.ledger": "https://github.com/Eason3436/toolbox/releases/download/ledger-latest/Ledger.ipa",
        "com.eason3436.screenshots": "https://github.com/Eason3436/toolbox/releases/download/screenshots-latest/Screenshots.ipa",
        "com.eason3436.recap": "https://github.com/Eason3436/toolbox/releases/download/recap-latest/Recap.ipa",
    ]

    private var autoReplace = Set<String>()
    private var queue: [String] = []
    private var alerted = Set<String>()

    private init() {
        links = UserDefaults.standard.dictionary(forKey: Self.linksKey) as? [String: String] ?? [:]
    }

    // MARK: Links

    func link(for bundleId: String) -> String? {
        if let link = links[bundleId] { return link }
        let disabled = UserDefaults.standard.stringArray(forKey: Self.disabledDefaultsKey) ?? []
        if disabled.contains(bundleId) { return nil }
        return Self.defaultLinks[bundleId]
    }

    func setLink(_ value: String?, for bundleId: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var disabled = UserDefaults.standard.stringArray(forKey: Self.disabledDefaultsKey) ?? []
        if trimmed.isEmpty {
            links.removeValue(forKey: bundleId)
            if Self.defaultLinks[bundleId] != nil && !disabled.contains(bundleId) { disabled.append(bundleId) }
        } else {
            links[bundleId] = trimmed
            disabled.removeAll { $0 == bundleId }
        }
        UserDefaults.standard.set(links, forKey: Self.linksKey)
        UserDefaults.standard.set(disabled, forKey: Self.disabledDefaultsKey)
        remote.removeValue(forKey: bundleId)
        errors.removeValue(forKey: bundleId)
        alerted.remove(bundleId)
    }

    // MARK: Status

    static func installedDate(of app: LCAppModel) -> Date? {
        if let date = app.appInfo.installationDate { return date }
        let attrs = try? FileManager.default.attributesOfItem(atPath: app.appInfo.bundlePath())
        return attrs?[.modificationDate] as? Date
    }

    func hasUpdate(_ app: LCAppModel) -> Bool {
        guard let bundleId = app.appInfo.bundleIdentifier(), link(for: bundleId) != nil,
              let info = remote[bundleId] else { return false }
        guard let installed = Self.installedDate(of: app) else { return true }
        // a minute of slack so a fresh install never shows as outdated
        return info.date.timeIntervalSince(installed) > 60
    }

    func updatableApps(in apps: [LCAppModel]) -> [LCAppModel] {
        apps.filter { hasUpdate($0) }
    }

    // MARK: Checking

    /// Checks every app that has a link. Returns apps with an update that
    /// have not been announced yet in this session.
    @discardableResult
    func checkAll(apps: [LCAppModel], force: Bool = false) async -> [LCAppModel] {
        if checking { return [] }
        if !force, let lastChecked, Date().timeIntervalSince(lastChecked) < 120 { return [] }
        checking = true
        defer { checking = false; lastChecked = Date() }

        let targets: [(String, String)] = apps.compactMap { app in
            guard let id = app.appInfo.bundleIdentifier(), let link = link(for: id) else { return nil }
            return (id, link)
        }
        await withTaskGroup(of: (String, Result<RemoteInfo, Error>).self) { group in
            for (id, link) in targets {
                group.addTask { (id, await Result { try await Self.fetchRemote(link) }) }
            }
            for await (id, result) in group {
                switch result {
                case .success(let info):
                    remote[id] = info
                    errors.removeValue(forKey: id)
                case .failure(let error):
                    errors[id] = error.localizedDescription
                }
            }
        }

        let fresh = updatableApps(in: apps).filter { !alerted.contains($0.appInfo.bundleIdentifier() ?? "") }
        for app in fresh { alerted.insert(app.appInfo.bundleIdentifier() ?? "") }
        return fresh
    }

    nonisolated static func fetchRemote(_ link: String) async throws -> RemoteInfo {
        guard let url = URL(string: link) else { throw "網址格式不對" }
        if let info = try await fetchGitHubRelease(url) { return info }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw "連結無法下載（\((response as? HTTPURLResponse)?.statusCode ?? 0)）"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let header = http.value(forHTTPHeaderField: "Last-Modified"),
              let date = formatter.date(from: header) else {
            throw "這個網站沒有提供檔案更新時間"
        }
        let size = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        return RemoteInfo(date: date, size: size)
    }

    /// github.com/<owner>/<repo>/releases/download/<tag>/<file>
    /// github.com/<owner>/<repo>/releases/latest/download/<file>
    private nonisolated static func fetchGitHubRelease(_ url: URL) async throws -> RemoteInfo? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5, parts[2] == "releases" else { return nil }
        let owner = parts[0], repo = parts[1]
        let api: String
        let file: String
        if parts[3] == "download", parts.count >= 6 {
            api = "https://api.github.com/repos/\(owner)/\(repo)/releases/tags/\(parts[4])"
            file = parts[5]
        } else if parts[3] == "latest", parts[4] == "download", parts.count >= 6 {
            api = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
            file = parts[5]
        } else {
            return nil
        }
        guard let apiURL = URL(string: api) else { return nil }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw "GitHub 上找不到這個 release（可能正在重新編譯）" }
        if status == 403 || status == 429 { throw "GitHub 查詢次數暫時用完，稍後再試" }
        guard status == 200 else { throw "GitHub 回應錯誤（\(status)）" }

        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let size: Int64; let updated_at: String }
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name == file }) else {
            throw "release 裡沒有 \(file)"
        }
        guard let date = ISO8601DateFormatter().date(from: asset.updated_at) else {
            throw "看不懂 GitHub 回傳的時間"
        }
        return RemoteInfo(date: date, size: asset.size)
    }

    // MARK: Installing

    func update(_ app: LCAppModel) {
        guard let id = app.appInfo.bundleIdentifier() else { return }
        queue.removeAll { $0 == id }
        queue.insert(id, at: 0)
        startNext()
    }

    func updateAll(_ apps: [LCAppModel]) {
        for app in apps {
            if let id = app.appInfo.bundleIdentifier(), !queue.contains(id) { queue.append(id) }
        }
        startNext()
    }

    private var current: String?

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let link = link(for: id), let url = URL(string: link) else { startNext(); return }
        current = id
        autoReplace.insert(id)
        NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": url])
        // if the install never finishes (error, cancelled), don't block the rest forever
        let token = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            guard let self, self.current == token else { return }
            self.current = nil
            self.autoReplace.remove(token)
            self.startNext()
        }
    }

    /// Called by the installer: true means replace the existing copy without asking.
    func consumeAutoReplace(bundleId: String?) -> Bool {
        guard let bundleId, autoReplace.contains(bundleId) else { return false }
        autoReplace.remove(bundleId)
        return true
    }

    /// Called by the installer after an app finished installing.
    func installFinished(bundleId: String?) {
        if let bundleId {
            autoReplace.remove(bundleId)
            alerted.remove(bundleId)
        }
        objectWillChange.send()
        if current != nil && current == bundleId {
            current = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.startNext()
            }
        }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

// MARK: - App list hook

extension View {
    /// Adds the update button, the update sheet, and the automatic check.
    func lcAppUpdates() -> some View { modifier(LCAppUpdatesModifier()) }
}

struct LCAppUpdatesModifier: ViewModifier {
    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var checker = LCUpdateChecker.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSheet = false
    @State private var showAlert = false
    @State private var newlyFound: [LCAppModel] = []

    private var apps: [LCAppModel] {
        sharedModel.apps + (sharedModel.isHiddenAppUnlocked ? sharedModel.hiddenApps : [])
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if sharedModel.multiLCStatus != 2 {
                        Button {
                            showSheet = true
                        } label: {
                            let count = checker.updatableApps(in: apps).count
                            Image(systemName: count > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .foregroundColor(count > 0 ? .red : nil)
                        }
                        .accessibilityLabel("App 更新")
                    }
                }
            }
            .sheet(isPresented: $showSheet) {
                LCAppUpdatesView(apps: apps, onClose: { showSheet = false })
                    .environmentObject(sharedModel)
            }
            .alert("有 App 可以更新", isPresented: $showAlert) {
                Button("全部更新") { checker.updateAll(newlyFound) }
                Button("查看") { showSheet = true }
                Button("稍後", role: .cancel) {}
            } message: {
                Text(newlyFound.map { $0.appInfo.displayName() ?? "" }.joined(separator: "、"))
            }
            .onAppear { check() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { check() }
            }
    }

    private func check() {
        guard sharedModel.multiLCStatus != 2 else { return }
        Task {
            let found = await checker.checkAll(apps: apps)
            if !found.isEmpty && !showSheet {
                newlyFound = found
                showAlert = true
            }
        }
    }
}

// MARK: - Update list

struct LCAppUpdatesView: View {
    let apps: [LCAppModel]
    var onClose: () -> Void
    @ObservedObject private var checker = LCUpdateChecker.shared

    var body: some View {
        NavigationView {
            List {
                let updatable = checker.updatableApps(in: apps)
                if !updatable.isEmpty {
                    Section {
                        Button {
                            checker.updateAll(updatable)
                            onClose()
                        } label: {
                            Label("全部更新（\(updatable.count)）", systemImage: "arrow.down.circle.fill")
                        }
                    }
                }
                Section {
                    ForEach(apps, id: \.self) { app in
                        NavigationLink(destination: LCAppUpdateLinkView(app: app, onUpdate: onClose)) {
                            LCAppUpdateRow(app: app, onUpdate: onClose)
                        }
                    }
                } footer: {
                    Text("點 App 可以設定它的下載連結（例如 GitHub Releases 的 .ipa 連結）。每次打開 LiveContainer 都會檢查連結上的檔案是不是比裝好的版本新。")
                }
            }
            .navigationTitle("App 更新")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if checker.checking {
                        ProgressView()
                    } else {
                        Button {
                            Task { await checker.checkAll(apps: apps, force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: onClose)
                }
            }
            .task { await checker.checkAll(apps: apps) }
        }
    }
}

private let updateDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    return f
}()

struct LCAppUpdateRow: View {
    @ObservedObject var app: LCAppModel
    var onUpdate: () -> Void
    @ObservedObject private var checker = LCUpdateChecker.shared

    var body: some View {
        let id = app.appInfo.bundleIdentifier() ?? ""
        HStack(spacing: 12) {
            Image(uiImage: app.appInfo.iconIsDarkIcon(false) ?? UIImage())
                .resizable()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appInfo.displayName() ?? id).font(.body)
                Text(status(id: id)).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer()
            if checker.hasUpdate(app) {
                Button("更新") {
                    checker.update(app)
                    onUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func status(id: String) -> String {
        guard checker.link(for: id) != nil else { return "未設定下載連結" }
        if let error = checker.errors[id] { return error }
        guard let info = checker.remote[id] else { return checker.checking ? "檢查中…" : "尚未檢查" }
        let when = updateDateFormatter.string(from: info.date)
        return checker.hasUpdate(app) ? "有新版本（\(when)）" : "已是最新（\(when)）"
    }
}

struct LCAppUpdateLinkView: View {
    @ObservedObject var app: LCAppModel
    var onUpdate: () -> Void
    @ObservedObject private var checker = LCUpdateChecker.shared
    @State private var text = ""
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        let id = app.appInfo.bundleIdentifier() ?? ""
        Form {
            Section {
                TextField("https://github.com/…/releases/download/…/App.ipa", text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Button("從剪貼簿貼上") {
                    if let s = UIPasteboard.general.string { text = s }
                }
            } header: {
                Text("下載連結")
            } footer: {
                Text("支援 GitHub Releases 連結（…/releases/download/<tag>/<檔名>.ipa 或 …/releases/latest/download/<檔名>.ipa），也支援有提供 Last-Modified 的一般 .ipa 網址。清空就是不檢查。")
            }
            Section {
                Button("儲存並檢查") {
                    checker.setLink(text, for: id)
                    Task { await checker.checkAll(apps: [app], force: true) }
                }
                Button("立即下載並更新") {
                    checker.setLink(text, for: id)
                    checker.update(app)
                    onUpdate()
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section {
                LabeledContentCompat(title: "Bundle ID", value: id)
                if let installed = LCUpdateChecker.installedDate(of: app) {
                    LabeledContentCompat(title: "目前安裝", value: updateDateFormatter.string(from: installed))
                }
                if let info = checker.remote[id] {
                    LabeledContentCompat(title: "連結上的檔案", value: updateDateFormatter.string(from: info.date))
                }
                if let error = checker.errors[id] {
                    Text(error).foregroundColor(.red)
                }
            }
        }
        .navigationTitle(app.appInfo.displayName() ?? id)
        .onAppear { text = checker.link(for: id) ?? "" }
    }
}

private struct LabeledContentCompat: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
