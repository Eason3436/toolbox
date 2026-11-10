//
//  LCLiveActivityAttributes.swift
//
//  Added by Eason3436/toolbox: a general-purpose Live Activity that apps
//  running inside LiveContainer can start.
//
//  Why: an app inside LiveContainer runs in LiveContainer's process, so iOS
//  treats its Live Activities as LiveContainer's. The system draws them with
//  LiveContainer's own widget extension, which can't know the guest app's
//  attribute types. LiveContainer therefore ships one widget
//  (LCLiveActivityWidget) for this one type, and guest apps use it.
//
//  Guest apps: copy this file into your app unchanged (the struct name and
//  field names must match; ActivityKit matches by type name), keep
//  NSSupportsLiveActivities = YES in your Info.plist, and call
//
//      let activity = try Activity.request(
//          attributes: LCLiveActivityAttributes.forCurrentApp(),
//          content: ActivityContent(state: .init(title: "錄音中", timerStart: .now), staleDate: nil))
//
//  All fields except `title` are optional, so older and newer copies of this
//  file stay compatible with each other.
//

import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct LCLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Main line (lock screen and expanded Dynamic Island).
        var title: String
        /// Second line, e.g. a status or the latest caption.
        var subtitle: String?
        /// SF Symbol name; falls back to the attributes' symbol.
        var systemImage: String?
        /// 0...1 shows a progress bar (and a ring in the compact island).
        var progress: Double?
        /// Counts up from this time (e.g. recording started).
        var timerStart: Date?
        /// Counts down to this time. Ignored when timerStart is set.
        var timerEnd: Date?
        /// Short text for the compact Dynamic Island when there is no timer or progress.
        var compactText: String?
        /// Accent color as hex ("#FF3B30"); falls back to the attributes' tint.
        var tintHex: String?

        init(title: String, subtitle: String? = nil, systemImage: String? = nil,
             progress: Double? = nil, timerStart: Date? = nil, timerEnd: Date? = nil,
             compactText: String? = nil, tintHex: String? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.systemImage = systemImage
            self.progress = progress
            self.timerStart = timerStart
            self.timerEnd = timerEnd
            self.compactText = compactText
            self.tintHex = tintHex
        }
    }

    /// Shown as the source of the activity.
    var appName: String
    /// The guest's folder name in LiveContainer (used to open it when tapped). Empty = just open LiveContainer.
    var bundleName: String
    /// Data container folder name, if the app has more than one container.
    var containerName: String?
    /// URL handed to the guest app when the activity is tapped (its own scheme or a universal link).
    var openURL: String?
    /// URL scheme of the LiveContainer that runs the app ("livecontainer", "livecontainer2", ...).
    var lcScheme: String?
    /// Default SF Symbol.
    var systemImage: String?
    /// Default accent color as hex.
    var tintHex: String?

    init(appName: String, bundleName: String, containerName: String? = nil, openURL: String? = nil,
         lcScheme: String? = nil, systemImage: String? = nil, tintHex: String? = nil) {
        self.appName = appName
        self.bundleName = bundleName
        self.containerName = containerName
        self.openURL = openURL
        self.lcScheme = lcScheme
        self.systemImage = systemImage
        self.tintHex = tintHex
    }
}

@available(iOS 16.2, *)
extension LCLiveActivityAttributes {
    /// True when this code runs as an app inside LiveContainer.
    static var isInsideLiveContainer: Bool {
        guard NSClassFromString("LCSharedUtils") != nil else { return false }
        // LiveContainer points Bundle.main at the guest app, so a guest has its own bundle ID.
        return !(Bundle.main.bundleIdentifier ?? "").hasPrefix("com.kdt.livecontainer")
    }

    /// Attributes filled in for the app that is running now.
    static func forCurrentApp(openURL: URL? = nil, systemImage: String? = nil, tintHex: String? = nil) -> LCLiveActivityAttributes {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "App"
        let inside = isInsideLiveContainer
        var scheme: String? = nil
        // +[NSUserDefaults lcAppUrlScheme] is LiveContainer's own category.
        let selector = NSSelectorFromString("lcAppUrlScheme")
        let defaultsClass: AnyObject = UserDefaults.self
        if inside, defaultsClass.responds(to: selector),
           let value = defaultsClass.perform(selector)?.takeUnretainedValue() as? String {
            scheme = value
        }
        return LCLiveActivityAttributes(
            appName: name,
            bundleName: inside ? Bundle.main.bundleURL.lastPathComponent : "",
            containerName: inside ? URL(fileURLWithPath: NSHomeDirectory()).lastPathComponent : nil,
            openURL: openURL?.absoluteString,
            lcScheme: scheme,
            systemImage: systemImage,
            tintHex: tintHex
        )
    }

    /// Where a tap on the activity goes. nil = just bring LiveContainer (and the running app) forward.
    var launchURL: URL? {
        guard !bundleName.isEmpty else { return nil }
        var comps = URLComponents()
        comps.scheme = lcScheme ?? "livecontainer"
        comps.host = "livecontainer-launch"
        var items = [URLQueryItem(name: "bundle-name", value: bundleName)]
        if let containerName, !containerName.isEmpty {
            items.append(URLQueryItem(name: "container-folder-name", value: containerName))
        }
        if let openURL, let data = openURL.data(using: .utf8) {
            items.append(URLQueryItem(name: "open-url", value: data.base64EncodedString()))
        }
        comps.queryItems = items
        return comps.url
    }
}
