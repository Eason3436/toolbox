import XCTest
@testable import Core

final class AudioTrackTests: XCTestCase {
    private func track(_ lang: String?, _ format: String, _ subtype: String, channels: Int? = 6,
                       playable: Bool = true, isDefault: Bool = false) -> AudioTrackInfo {
        AudioTrackInfo(languageTag: lang, title: nil, format: format, subtype: subtype, channels: channels,
                       isAtmos: false, playable: playable, isDefault: isDefault)
    }

    func testResolveOrder() {
        let tracks = [
            track("ja", "TrueHD", "lpcm"),
            track("en", "E-AC3", "ec-3", isDefault: true),
            track("zh", "AAC", "mp4a", channels: 2),
            track("ja", "DTS", "dtsc", playable: false),
        ]
        // 自己選的優先；選到不能播的不算
        XCTAssertEqual(AudioTrackSelection.resolve(tracks, choice: 2, key: nil, language: .english), 2)
        XCTAssertEqual(AudioTrackSelection.resolve(tracks, choice: 3, key: nil, language: nil), 1)
        // 劇集記住的
        let key = AudioTrackKey(languageTag: "jpn", format: "TrueHD", channels: 6)
        XCTAssertEqual(AudioTrackSelection.resolve(tracks, choice: nil, key: key, language: .english), 0)
        // 設定的語言
        XCTAssertEqual(AudioTrackSelection.resolve(tracks, choice: nil, key: nil, language: .traditionalChinese), 2)
        // 檔案的預設
        XCTAssertEqual(AudioTrackSelection.resolve(tracks, choice: nil, key: nil, language: .korean), 1)
        XCTAssertEqual(AudioTrackSelection.resolve([], choice: nil, key: nil, language: nil), nil)
    }

    func testKeyPrefersSameFormat() {
        let tracks = [track("ja", "AAC", "mp4a", channels: 2), track("ja", "TrueHD", "lpcm"), track("en", "TrueHD", "lpcm")]
        XCTAssertEqual(AudioTrackSelection.bestIndex(for: AudioTrackKey(languageTag: "ja", format: "TrueHD", channels: 8), in: tracks), 1)
        XCTAssertEqual(AudioTrackSelection.bestIndex(for: AudioTrackKey(languageTag: "ja", format: "AAC", channels: 2), in: tracks), 0)
        XCTAssertNil(AudioTrackSelection.bestIndex(for: AudioTrackKey(languageTag: "ko", format: "AAC", channels: 2), in: tracks))
    }

    func testOptionIndex() {
        let tracks = ["mp4a", "lpcm", "lpcm"]
        XCTAssertEqual(AudioTrackSelection.optionIndex(track: 2, trackSubtypes: tracks, optionSubtypes: [["mp4a"], ["lpcm"], ["lpcm"]]), 2)
        // 少一個選項：用同樣編碼的第幾個
        XCTAssertEqual(AudioTrackSelection.optionIndex(track: 1, trackSubtypes: tracks, optionSubtypes: [["lpcm"], ["lpcm"]]), 0)
        // 選項沒有編碼資訊、數量一樣：用位置
        XCTAssertEqual(AudioTrackSelection.optionIndex(track: 1, trackSubtypes: tracks, optionSubtypes: [[], [], []]), 1)
        XCTAssertNil(AudioTrackSelection.optionIndex(track: 1, trackSubtypes: tracks, optionSubtypes: [[]]))
    }
}
