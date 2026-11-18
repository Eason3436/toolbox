//
//  LCAppWidget.swift
//  LCLiveActivityWidget
//
//  Added by Eason3436/toolbox: home screen and lock screen widget for apps
//  running inside LiveContainer. Guest apps write an LCWidgetSnapshot JSON into
//  <LiveContainer app group>/LCWidgets/; the person picks which app in the
//  widget's settings (long press → Edit Widget). See LCWidgetSnapshot.swift.
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Reading the snapshots

enum LCWidgetStore {
    /// LiveContainer's app group folder. SideStore / AltStore add the team ID to the
    /// group name, so read the real names from the provisioning profile.
    static var folder: URL? {
        let manager = FileManager.default
        var candidates = provisionedAppGroups()
        candidates += ["group.com.SideStore.SideStore", "group.com.rileytestut.AltStore"]
        let containers = candidates.compactMap { manager.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        let folders = containers.map { $0.appendingPathComponent(LCWidgetSnapshot.folderName, isDirectory: true) }
        return folders.first { manager.fileExists(atPath: $0.path) } ?? folders.first
    }

    static func all() -> [LCWidgetSnapshot] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? LCWidgetSnapshot.decoder.decode(LCWidgetSnapshot.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func snapshot(bundleName: String?) -> LCWidgetSnapshot? {
        let snapshots = all()
        guard let bundleName else { return snapshots.first }
        return snapshots.first { $0.bundleName == bundleName } ?? snapshots.first
    }

    /// App groups granted to this extension (or to LiveContainer itself) by the signing profile.
    private static func provisionedAppGroups() -> [String] {
        let extensionProfile = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        // LiveContainer.app/PlugIns/xxx.appex → LiveContainer.app
        let appProfile = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("embedded.mobileprovision")
        for url in [extensionProfile, appProfile] {
            guard let data = try? Data(contentsOf: url),
                  let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any],
                  let groups = entitlements["com.apple.security.application-groups"] as? [String],
                  !groups.isEmpty
            else { continue }
            return groups
        }
        return []
    }
}

// MARK: - Choosing the app

struct LCWidgetAppEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static var defaultQuery = LCWidgetAppQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct LCWidgetAppQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LCWidgetAppEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [LCWidgetAppEntity] {
        LCWidgetStore.all().map { LCWidgetAppEntity(id: $0.bundleName, name: $0.appName) }
    }

    func defaultResult() async -> LCWidgetAppEntity? {
        try? await suggestedEntities().first
    }
}

struct LCAppWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "LiveContainer App"
    static var description = IntentDescription("Shows numbers from an app inside LiveContainer.")

    @Parameter(title: "App")
    var app: LCWidgetAppEntity?
}

// MARK: - Timeline

struct LCAppWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: LCWidgetSnapshot?
    let entry: LCWidgetSnapshot.Entry?
}

struct LCAppWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LCAppWidgetEntry {
        LCAppWidgetEntry(date: .now, snapshot: nil,
                         entry: .init(date: .now, value: "12", caption: "Today", subtitle: "LiveContainer"))
    }

    func snapshot(for configuration: LCAppWidgetIntent, in context: Context) async -> LCAppWidgetEntry {
        let snapshot = LCWidgetStore.snapshot(bundleName: configuration.app?.id)
        return LCAppWidgetEntry(date: .now, snapshot: snapshot, entry: snapshot?.entry(at: .now))
    }

    func timeline(for configuration: LCAppWidgetIntent, in context: Context) async -> Timeline<LCAppWidgetEntry> {
        let now = Date()
        guard let snapshot = LCWidgetStore.snapshot(bundleName: configuration.app?.id) else {
            return Timeline(entries: [LCAppWidgetEntry(date: now, snapshot: nil, entry: nil)],
                            policy: .after(now.addingTimeInterval(30 * 60)))
        }
        var entries = [LCAppWidgetEntry(date: now, snapshot: snapshot, entry: snapshot.entry(at: now))]
        for item in snapshot.entries.sorted(by: { $0.date < $1.date }) where item.date > now {
            entries.append(LCAppWidgetEntry(date: item.date, snapshot: snapshot, entry: item))
        }
        // The app rewrites the file every time it's used; re-read now and then in case reload didn't reach us.
        let next = min(entries.last?.date ?? now, now.addingTimeInterval(2 * 3600))
        return Timeline(entries: entries, policy: .after(max(next, now.addingTimeInterval(15 * 60))))
    }
}

// MARK: - Views

struct LCAppWidgetView: View {
    let item: LCAppWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var tint: Color { widgetColor(hex: item.snapshot?.tintHex) ?? .accentColor }
    private var symbol: String { item.snapshot?.systemImage ?? "app.fill" }

    var body: some View {
        Group {
            if let entry = item.entry {
                switch family {
                case .accessoryCircular: circular(entry)
                case .accessoryRectangular: rectangular(entry)
                case .accessoryInline: inline(entry)
                case .systemMedium: medium(entry)
                default: small(entry)
                }
            } else {
                empty
            }
        }
        .widgetURL(item.snapshot?.launchURL)
        .containerBackground(.background, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(item.snapshot?.appName ?? "LiveContainer")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func valueBlock(_ entry: LCWidgetSnapshot.Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.value)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
            if let caption = entry.caption {
                Text(caption)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
        }
    }

    private func small(_ entry: LCWidgetSnapshot.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            valueBlock(entry)
            if let subtitle = entry.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(_ entry: LCWidgetSnapshot.Entry) -> some View {
        HStack(alignment: .top, spacing: 16) {
            small(entry)
            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 0)
                ForEach(Array((entry.details ?? []).prefix(3).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let progress = entry.progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(tint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func circular(_ entry: LCWidgetSnapshot.Entry) -> some View {
        Gauge(value: min(max(entry.progress ?? 0, 0), 1)) {
            Image(systemName: symbol)
        } currentValueLabel: {
            Text(entry.value)
                .minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private func rectangular(_ entry: LCWidgetSnapshot.Entry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(item.snapshot?.appName ?? "")
                    .lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            Text("\(entry.value) \(entry.caption ?? "")")
                .font(.headline)
                .lineLimit(1)
            if let subtitle = entry.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ entry: LCWidgetSnapshot.Entry) -> some View {
        Label("\(entry.value) \(entry.caption ?? "")", systemImage: symbol)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            Text("Open the app in LiveContainer once.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct LCAppWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LCAppWidget", intent: LCAppWidgetIntent.self, provider: LCAppWidgetProvider()) { item in
            LCAppWidgetView(item: item)
        }
        .configurationDisplayName("App")
        .description("Numbers from an app inside LiveContainer.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private func widgetColor(hex: String?) -> Color? {
    guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, let value = UInt64(text, radix: 16) else { return nil }
    return Color(.sRGB,
                 red: Double((value >> 16) & 0xFF) / 255,
                 green: Double((value >> 8) & 0xFF) / 255,
                 blue: Double(value & 0xFF) / 255)
}
