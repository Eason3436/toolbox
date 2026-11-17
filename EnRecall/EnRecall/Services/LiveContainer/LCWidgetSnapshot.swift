//
//  LCWidgetSnapshot.swift
//
//  Added by Eason3436/toolbox: a general-purpose home screen / lock screen
//  widget for apps running inside LiveContainer.
//
//  Why: a guest app can't ship its own widget extension (iOS only loads
//  extensions of apps that are really installed). LiveContainer's widget
//  extension therefore draws one generic widget, and guest apps hand it
//  their numbers as a JSON file in LiveContainer's app group:
//
//      <app group>/LCWidgets/<guest bundle ID>.json
//
//  The guest finds the app group path with +[NSUserDefaults lcAppGroupPath]
//  (LiveContainer's own category), writes the file with `LCWidgetSnapshot.encoder`,
//  then calls WidgetCenter.shared.reloadAllTimelines().
//
//  Guests: copy this file into your app unchanged. Every field except
//  appName / bundleName / updatedAt / entries is optional, so older and newer
//  copies stay compatible.
//

import Foundation

struct LCWidgetSnapshot: Codable, Equatable {
    /// One state of the widget. The widget shows the last entry whose date has passed,
    /// so an app can precompute how its numbers change over the next hours.
    struct Entry: Codable, Equatable {
        var date: Date
        /// Big number or short text, e.g. "52".
        var value: String
        /// Under the value, e.g. "張要背".
        var caption: String?
        /// Small line, e.g. "複習 40 · 新字 12".
        var subtitle: String?
        /// Extra lines for the medium widget.
        var details: [String]?
        /// 0...1 shows a bar (medium) or a ring (lock screen circle).
        var progress: Double?

        init(date: Date, value: String, caption: String? = nil, subtitle: String? = nil,
             details: [String]? = nil, progress: Double? = nil) {
            self.date = date
            self.value = value
            self.caption = caption
            self.subtitle = subtitle
            self.details = details
            self.progress = progress
        }
    }

    var version: Int = 1
    /// Shown on the widget and in the widget's app picker.
    var appName: String
    /// The guest's folder name in LiveContainer (used to open it when tapped).
    var bundleName: String
    /// Data container folder name, if the app has more than one container.
    var containerName: String?
    /// URL scheme of the LiveContainer that runs the app ("livecontainer", "livecontainer2", ...).
    var lcScheme: String?
    /// URL handed to the guest app when the widget is tapped.
    var openURL: String?
    /// SF Symbol.
    var systemImage: String?
    /// Accent color as hex ("#4F6C54").
    var tintHex: String?
    var updatedAt: Date
    var entries: [Entry]

    static let folderName = "LCWidgets"

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// What to show at `date`.
    func entry(at date: Date) -> Entry? {
        let sorted = entries.sorted { $0.date < $1.date }
        return sorted.last { $0.date <= date } ?? sorted.first
    }

    /// Where a tap on the widget goes (same format as LiveContainer's launch links).
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
