import Foundation

/// 一條音軌（詳細頁的音軌選單、播放時挑音軌用）。順序跟檔案裡的音軌一樣
public struct AudioTrackInfo: Codable, Sendable, Hashable {
    /// 語言（兩碼優先：「ja」「en」「zh-Hant」）；沒標是 nil
    public var languageTag: String?
    /// 音軌名稱（「導演講評」）
    public var title: String?
    /// 顯示用的格式（「TrueHD」「E-AC3」「AAC」）
    public var format: String
    /// sample entry 的 fourCC（「lpcm」「ec-3」）：對應播放器的音軌選項用
    public var subtype: String
    public var channels: Int?
    public var isAtmos: Bool
    /// iPhone 播得了
    public var playable: Bool
    /// 檔案標成預設的音軌
    public var isDefault: Bool

    public init(languageTag: String?, title: String?, format: String, subtype: String, channels: Int?,
                isAtmos: Bool, playable: Bool, isDefault: Bool) {
        self.languageTag = languageTag
        self.title = title
        self.format = format
        self.subtype = subtype
        self.channels = channels
        self.isAtmos = isAtmos
        self.playable = playable
        self.isDefault = isDefault
    }

    public var key: AudioTrackKey { AudioTrackKey(languageTag: languageTag, format: format, channels: channels) }
}

/// 劇集記住的音軌：每一集的音軌順序可能不一樣，用語言＋格式＋聲道找最像的
public struct AudioTrackKey: Codable, Sendable, Hashable {
    public var languageTag: String?
    public var format: String
    public var channels: Int?

    public init(languageTag: String?, format: String, channels: Int?) {
        self.languageTag = languageTag
        self.format = format
        self.channels = channels
    }
}

public enum AudioTrackSelection {
    /// 播放時用哪一條：自己選的 → 劇集記住的 → 設定的語言 → 檔案的預設 → 第一條能播的
    public static func resolve(_ tracks: [AudioTrackInfo], choice: Int?, key: AudioTrackKey?,
                               language: MediaLanguage?) -> Int? {
        if let choice, tracks.indices.contains(choice), tracks[choice].playable { return choice }
        if let key, let i = bestIndex(for: key, in: tracks) { return i }
        let playable = tracks.indices.filter { tracks[$0].playable }
        if let language,
           let i = language.bestIndex(playable.map { (languageTag: tracks[$0].languageTag, name: tracks[$0].title ?? "") }) {
            return playable[i]
        }
        return playable.first { tracks[$0].isDefault } ?? playable.first
    }

    /// 最像的那條（語言一定要一樣；沒標語言的只比格式）
    public static func bestIndex(for key: AudioTrackKey, in tracks: [AudioTrackInfo]) -> Int? {
        var best: (index: Int, score: Int)?
        for (i, track) in tracks.enumerated() where track.playable {
            guard primary(track.languageTag) == primary(key.languageTag) else { continue }
            var score = 1
            if track.format == key.format { score += 2 }
            if track.channels == key.channels { score += 1 }
            if score > (best?.score ?? 0) { best = (i, score) }
        }
        return best?.index
    }

    /// 第幾條音軌 → 播放器的第幾個選項。選項跟音軌的順序一樣，
    /// 不過不一定每條音軌都有選項，所以先用同樣編碼的第幾個對，數量對不上才直接用位置
    public static func optionIndex(track: Int, trackSubtypes: [String], optionSubtypes: [[String]]) -> Int? {
        guard trackSubtypes.indices.contains(track) else { return nil }
        let subtype = trackSubtypes[track]
        let ordinal = trackSubtypes[..<track].filter { $0 == subtype }.count
        let sameTracks = trackSubtypes.filter { $0 == subtype }.count
        let sameOptions = optionSubtypes.indices.filter { optionSubtypes[$0].contains(subtype) }
        if sameOptions.count == sameTracks { return sameOptions[ordinal] }
        if optionSubtypes.count == trackSubtypes.count { return track }
        return nil
    }

    static func primary(_ tag: String?) -> String {
        let lower = (tag ?? "").lowercased()
        let primary = lower.split(separator: "-").first.map(String.init) ?? lower
        // ISO 639-2 → 兩碼（播放器有時給三碼）
        let map = ["jpn": "ja", "eng": "en", "chi": "zh", "zho": "zh", "kor": "ko", "fre": "fr", "fra": "fr",
                   "ger": "de", "deu": "de", "spa": "es", "ita": "it", "rus": "ru", "por": "pt", "tha": "th",
                   "cmn": "zh", "yue": "zh", "und": ""]
        return map[primary] ?? primary
    }
}
