//
//  LCShortcutIntents.swift
//  LaunchAppExtension
//
//  Added by Eason3436/toolbox: Shortcuts actions that reach apps installed
//  inside LiveContainer. iOS only reads App Intents from real installed
//  bundles, so these actions live in LiveContainer's own App Intents
//  extension and hand data to the guest app through a small inbox folder
//  inside the guest's data container:
//
//      <guest home>/Library/LCShortcutInbox/<time>-<uuid>.json
//
//  The guest app reads and deletes those files the next time it becomes
//  active (see LiveContainer/README.md in the toolbox repo for the format).
//

import AppIntents
import Foundation

// MARK: - Errors

private struct LCShortcutError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Installed guest apps

struct LCGuestApp {
    /// Folder name inside Applications/, which is what launch URLs call "bundle-name".
    let folderName: String
    let name: String
    let bundleId: String
    let isShared: Bool
    let dataUUID: String?
    let isHidden: Bool

    /// The guest's home folder (what the guest sees as NSHomeDirectory()).
    var homeURL: URL? {
        guard let dataUUID, let root = LCGuestCatalog.root(shared: isShared) else { return nil }
        return root.appendingPathComponent("Data/Application", isDirectory: true)
            .appendingPathComponent(dataUUID, isDirectory: true)
    }

    var launchURL: URL {
        var comps = URLComponents()
        comps.scheme = "livecontainer"
        comps.host = "livecontainer-launch"
        comps.queryItems = [URLQueryItem(name: "bundle-name", value: folderName)]
        return comps.url!
    }
}

enum LCGuestCatalog {
    /// Gives this extension access to LiveContainer's private Documents folder.
    /// LiveContainer saves a bookmark for it the first time the main app opens.
    static func ensureDocumentsAccess() {
        if LaunchAppExtension.bookmarkResolved { return }
        guard let groupId = LCSharedUtils.appGroupID(),
              let defaults = UserDefaults(suiteName: groupId),
              let data = defaults.data(forKey: "LCLaunchExtensionPrivateDocBookmark") else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
           url.startAccessingSecurityScopedResource() {
            setenv("LC_HOME_PATH", (url.deletingLastPathComponent().path as NSString).utf8String, 1)
            LaunchAppExtension.bookmarkResolved = true
        }
    }

    /// Documents/ of LiveContainer (private apps) or LiveContainer/ in the app group (shared apps).
    static func root(shared: Bool) -> URL? {
        if shared {
            return LCSharedUtils.appGroupPath()?.appendingPathComponent("LiveContainer", isDirectory: true)
        }
        guard let home = getenv("LC_HOME_PATH") else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }

    static func allApps(includeHidden: Bool = false) -> [LCGuestApp] {
        ensureDocumentsAccess()
        var result: [LCGuestApp] = []
        var seen = Set<String>()
        for shared in [false, true] {
            guard let apps = root(shared: shared)?.appendingPathComponent("Applications", isDirectory: true),
                  let folders = try? FileManager.default.contentsOfDirectory(atPath: apps.path) else { continue }
            for folder in folders.sorted() where !seen.contains(folder) {
                let bundle = apps.appendingPathComponent(folder, isDirectory: true)
                guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")) as? [String: Any] else { continue }
                let lcInfo = NSDictionary(contentsOf: bundle.appendingPathComponent("LCAppInfo.plist")) as? [String: Any] ?? [:]
                let hidden = lcInfo["isHidden"] as? Bool ?? false
                if hidden && !includeHidden { continue }
                let usesLCBundleId = lcInfo["doUseLCBundleId"] as? Bool ?? false
                let bundleId = (usesLCBundleId ? lcInfo["LCOrignalBundleIdentifier"] as? String : nil)
                    ?? info["CFBundleIdentifier"] as? String ?? folder
                let name = info["CFBundleDisplayName"] as? String
                    ?? info["CFBundleName"] as? String ?? folder
                seen.insert(folder)
                result.append(LCGuestApp(folderName: folder, name: name, bundleId: bundleId, isShared: shared,
                                         dataUUID: lcInfo["LCDataUUID"] as? String, isHidden: hidden))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func app(folderName: String) -> LCGuestApp? {
        allApps(includeHidden: true).first { $0.folderName == folderName }
    }

    static func app(bundleId: String) -> LCGuestApp? {
        allApps(includeHidden: true).first { $0.bundleId == bundleId }
    }

    static func noAppsHint() -> String {
        if getenv("LC_HOME_PATH") == nil {
            return "請先打開一次 LiveContainer，讓捷徑取得讀取 App 清單的權限。"
        }
        return "LiveContainer 裡沒有找到這個 App。"
    }
}

// MARK: - Inbox

enum LCShortcutInbox {
    static let folder = "Library/LCShortcutInbox"

    /// Writes one request into the guest's inbox. Returns the file it wrote.
    @discardableResult
    static func post(to app: LCGuestApp, action: String, text: String?, params: [String: Any] = [:]) throws -> URL {
        guard let home = app.homeURL else {
            throw LCShortcutError("找不到「\(app.name)」的資料夾。請先在 LiveContainer 打開它一次。")
        }
        let dir = home.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let now = Date()
        var payload: [String: Any] = [
            "version": 1,
            "id": id,
            "action": action,
            "createdAt": ISO8601DateFormatter().string(from: now),
            "source": "LiveContainer",
        ]
        if let text { payload["text"] = text }
        if !params.isEmpty { payload["params"] = params }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        let file = dir.appendingPathComponent("\(millis)-\(id).json")
        try data.write(to: file, options: .atomic)
        return file
    }

    static func launch(_ app: LCGuestApp, openURL: String? = nil) async throws {
        var comps = URLComponents(url: app.launchURL, resolvingAgainstBaseURL: false)!
        if let openURL, !openURL.isEmpty {
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "open-url", value: Data(openURL.utf8).base64EncodedString()))
            comps.queryItems = items
        }
        guard let url = comps.url else { throw LCShortcutError("無法建立啟動網址") }
        var launcher = LaunchAppExtension()
        launcher.launchURL = url
        _ = try await launcher.perform()
    }
}

// MARK: - App entity (lets Shortcuts show a picker of installed apps)

struct LCGuestAppEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "LiveContainer App" }
    static var defaultQuery: LCGuestAppQuery { LCGuestAppQuery() }

    var id: String
    var name: String
    var bundleId: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(bundleId)")
    }

    init(_ app: LCGuestApp) {
        id = app.folderName
        name = app.name
        bundleId = app.bundleId
    }
}

struct LCGuestAppQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LCGuestAppEntity] {
        let apps = LCGuestCatalog.allApps(includeHidden: true)
        return identifiers.compactMap { id in apps.first { $0.folderName == id }.map(LCGuestAppEntity.init) }
    }

    func entities(matching string: String) async throws -> [LCGuestAppEntity] {
        LCGuestCatalog.allApps()
            .filter { $0.name.localizedCaseInsensitiveContains(string) || $0.bundleId.localizedCaseInsensitiveContains(string) }
            .map(LCGuestAppEntity.init)
    }

    func suggestedEntities() async throws -> [LCGuestAppEntity] {
        LCGuestCatalog.allApps().map(LCGuestAppEntity.init)
    }
}

private func resolve(_ entity: LCGuestAppEntity) throws -> LCGuestApp {
    guard let app = LCGuestCatalog.app(folderName: entity.id) else {
        throw LCShortcutError(LCGuestCatalog.noAppsHint())
    }
    return app
}

// MARK: - Generic actions

struct OpenGuestAppIntent: AppIntent {
    static var title: LocalizedStringResource { "開啟 LiveContainer 裡的 App" }
    static var description: IntentDescription {
        IntentDescription("直接從清單選一個裝在 LiveContainer 裡的 App 打開，可以順便把一個網址（例如 App 自己的 URL scheme）交給它。")
    }

    @Parameter(title: "App")
    var app: LCGuestAppEntity

    @Parameter(title: "交給 App 的網址", description: "選填。會像點連結一樣交給這個 App 處理。")
    var url: String?

    static var parameterSummary: some ParameterSummary {
        Summary("打開 \(\.$app)") { \.$url }
    }

    func perform() async throws -> some IntentResult {
        try await LCShortcutInbox.launch(try resolve(app), openURL: url)
        return .result()
    }
}

struct SendToGuestAppIntent: AppIntent {
    static var title: LocalizedStringResource { "傳送資料給 LiveContainer 裡的 App" }
    static var description: IntentDescription {
        IntentDescription("在背景把文字放進 App 的收件匣（不會打開 App）。App 下次打開時會讀取並處理。App 需要支援 LCShortcutInbox。")
    }

    @Parameter(title: "App")
    var app: LCGuestAppEntity

    @Parameter(title: "動作名稱", description: "App 認得的動作代號，例如 ledger.logNotification")
    var action: String

    @Parameter(title: "文字")
    var text: String

    @Parameter(title: "完成後打開 App", default: false)
    var openApp: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$text) 用 \(\.$action) 傳給 \(\.$app)") { \.$openApp }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let guest = try resolve(app)
        try LCShortcutInbox.post(to: guest, action: action, text: text)
        if openApp { try await LCShortcutInbox.launch(guest) }
        return .result(dialog: IntentDialog(stringLiteral: "已傳給「\(guest.name)」"))
    }
}

// MARK: - 記帳 (Ledger) actions

private enum LedgerTarget {
    static let bundleId = "com.eason3436.ledger"

    static func find() throws -> LCGuestApp {
        guard let app = LCGuestCatalog.app(bundleId: bundleId) else {
            if getenv("LC_HOME_PATH") == nil { throw LCShortcutError(LCGuestCatalog.noAppsHint()) }
            throw LCShortcutError("LiveContainer 裡沒有裝「記帳」(\(bundleId))。")
        }
        return app
    }

    static func queued(_ app: LCGuestApp, opened: Bool) -> String {
        opened ? "已交給「\(app.name)」，正在打開記帳。" : "已排進「\(app.name)」，下次打開記帳時會自動記錄。"
    }
}

struct LedgerLogNotificationIntent: AppIntent {
    static var title: LocalizedStringResource { "記帳：從通知記帳" }
    static var description: IntentDescription {
        IntentDescription(
            "把銀行、信用卡或電子支付的通知全文交給 LiveContainer 裡的「記帳」。記帳下次打開時會用 Apple Intelligence 拆出商家、金額與分類並記下來（日期用現在的時間）。",
            categoryName: "記帳"
        )
    }

    @Parameter(title: "通知內容", description: "通知的完整文字（標題＋內文）")
    var text: String

    @Parameter(title: "帳戶名稱", description: "留空時依卡號末四碼或預設帳戶自動選擇")
    var accountName: String?

    @Parameter(title: "完成後打開記帳", default: false)
    var openApp: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$text) 交給記帳") {
            \.$accountName
            \.$openApp
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let app = try LedgerTarget.find()
        var params: [String: Any] = [:]
        if let accountName, !accountName.isEmpty { params["accountName"] = accountName }
        try LCShortcutInbox.post(to: app, action: "ledger.logNotification", text: text, params: params)
        if openApp { try await LCShortcutInbox.launch(app) }
        let msg = LedgerTarget.queued(app, opened: openApp)
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct LedgerQuickAddIntent: AppIntent {
    static var title: LocalizedStringResource { "記帳：快速記一筆" }
    static var description: IntentDescription {
        IntentDescription(
            "用商家與金額記一筆支出到 LiveContainer 裡的「記帳」，分類會依商家自動判斷。適合搭配「錢包」交易自動化。",
            categoryName: "記帳"
        )
    }

    @Parameter(title: "商家")
    var merchant: String

    @Parameter(title: "金額")
    var amount: Double

    @Parameter(title: "帳戶名稱")
    var accountName: String?

    @Parameter(title: "完成後打開記帳", default: false)
    var openApp: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("記一筆 \(\.$merchant) \(\.$amount)") {
            \.$accountName
            \.$openApp
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let app = try LedgerTarget.find()
        var params: [String: Any] = ["merchant": merchant, "amount": amount]
        if let accountName, !accountName.isEmpty { params["accountName"] = accountName }
        try LCShortcutInbox.post(to: app, action: "ledger.quickAdd", text: merchant, params: params)
        if openApp { try await LCShortcutInbox.launch(app) }
        let msg = LedgerTarget.queued(app, opened: openApp)
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}
