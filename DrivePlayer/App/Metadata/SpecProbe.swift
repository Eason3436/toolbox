import AVFoundation
import Core
import CoreMedia
import Foundation

/// 用 AVURLAsset（透過本機代理）讀 track 資訊：解析度、HDR、杜比視界、音訊格式、聲道、全景聲
struct SpecInfo: Sendable {
    var duration: Double = 0
    var width: Int?
    var height: Int?
    var isHDR = false
    var isDolbyVision = false
    var hdrFormat: String?
    var audioFormat: String?
    var audioChannels: Int?
    var isAtmos = false
    /// 影片的編碼 iPhone 解不了（例如 H.264 10-bit）：播放時只有聲音
    var unsupportedVideo: String?
    /// 所有音軌的編碼都解不了（例如 DTS）：播放時沒有聲音
    var unsupportedAudio: String?
    /// 所有音軌（檔案裡的順序）
    var audioTracks: [AudioTrackInfo] = []
}

enum SpecProbe {
    /// 讀到的欄位變多就加 1，舊的會在開詳細頁時重讀（2：聲道、全景聲、HDR 種類；3：不支援的編碼；4：TrueHD 轉成 PCM；5：音軌清單）
    static let version = 5

    /// `truehd`：代理轉成 PCM 的 TrueHD 音軌（track ID → 原本的格式），標示照原本的格式
    static func probe(url: URL, truehd: [Int: TrueHDFormat] = [:]) async throws -> SpecInfo {
        let asset = AVURLAsset(url: url)
        var info = SpecInfo()
        let duration = try await asset.load(.duration)
        if duration.seconds.isFinite { info.duration = duration.seconds }

        for track in try await asset.loadTracks(withMediaType: .video) {
            let playable = try await track.load(.isPlayable)
            if let desc = try await track.load(.formatDescriptions).first {
                let codec = fourCC(CMFormatDescriptionGetMediaSubType(desc))
                if !playable {
                    info.unsupportedVideo = CodecNames.name(fourCC: codec)
                } else if codec == "avc1" || codec == "avc3",
                          let atoms = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
                          let avcC = atoms["avcC"] as? Data,
                          let profile = MP4Boxes.h264Profile(avcC: [UInt8](avcC)),
                          MP4Boxes.isUnsupportedH264Profile(profile) {
                    info.unsupportedVideo = "H.264 10-bit"
                }
            }
            let size = try await track.load(.naturalSize)
            info.width = Int(abs(size.width).rounded())
            info.height = Int(abs(size.height).rounded())
            let characteristics = try await track.load(.mediaCharacteristics)
            if characteristics.contains(.containsHDRVideo) { info.isHDR = true }
            for desc in try await track.load(.formatDescriptions) {
                if isDolbyVision(desc) { info.isDolbyVision = true }
                if let transfer = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                    if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                        info.isHDR = true
                        info.hdrFormat = "HDR10"
                    } else if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                        info.isHDR = true
                        info.hdrFormat = "HLG"
                    }
                }
            }
            break
        }

        info.audioTracks = try await audioTracks(asset, truehd: truehd)
        // 規格標示用預設會播的那條
        if let i = AudioTrackSelection.resolve(info.audioTracks, choice: nil, key: nil, language: nil) {
            let track = info.audioTracks[i]
            info.audioFormat = track.format
            info.audioChannels = track.channels
            info.isAtmos = track.isAtmos
        } else {
            info.unsupportedAudio = info.audioTracks.first?.format
        }
        return info
    }

    /// 播放時對音軌用（另外開一個 asset，資料代理已經快取了）
    static func audioTracks(url: URL, truehd: [Int: TrueHDFormat]) async throws -> [AudioTrackInfo] {
        try await audioTracks(AVURLAsset(url: url), truehd: truehd)
    }

    /// 所有音軌，檔案裡的順序（跟 `loadTracks(withMediaType: .audio)` 一樣）
    static func audioTracks(_ asset: AVAsset, truehd: [Int: TrueHDFormat]) async throws -> [AudioTrackInfo] {
        var out: [AudioTrackInfo] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let playable = try await track.load(.isPlayable)
            let enabled = try await track.load(.isEnabled)
            let descs = try await track.load(.formatDescriptions)
            let extendedTag = try await track.load(.extendedLanguageTag)
            let code = try await track.load(.languageCode)
            let metadata = (try? await track.load(.commonMetadata)) ?? []
            let desc = descs.first
            let subtype = desc.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
            var info = AudioTrackInfo(
                languageTag: languageTag(extendedTag ?? code), title: nil,
                format: desc.map { playable ? audioName(CMFormatDescriptionGetMediaSubType($0)) : CodecNames.name(fourCC: subtype) } ?? "?",
                subtype: subtype, channels: nil, isAtmos: false, playable: playable, isDefault: enabled)
            if let title = metadata.first(where: { $0.commonKey == .commonKeyTitle }),
               let value = try? await title.load(.stringValue), !value.isEmpty {
                info.title = value
            }
            if let desc {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee, asbd.mChannelsPerFrame > 0 {
                    info.channels = Int(asbd.mChannelsPerFrame)
                }
                // 杜比的設定盒比 ASBD 準（E-AC3 7.1、全景聲 JOC）
                if let atoms = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
                    if subtype == "ec-3", let data = atoms["dec3"] as? Data, let dolby = DolbyAudioConfig.parseDEC3([UInt8](data)) {
                        info.channels = dolby.channels
                        info.isAtmos = dolby.isAtmos
                    } else if subtype == "ac-3", let data = atoms["dac3"] as? Data, let dolby = DolbyAudioConfig.parseDAC3([UInt8](data)) {
                        info.channels = dolby.channels
                    }
                }
            }
            if let original = truehd[Int(track.trackID)] {
                info.format = "TrueHD"
                info.channels = original.channels
                info.isAtmos = original.isAtmos
            }
            out.append(info)
        }
        return out
    }

    /// 「jpn」→「ja」；沒標（und）是 nil
    static func languageTag(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.lowercased() != "und" else { return nil }
        if raw.count == 3, let code = Locale.LanguageCode(raw).identifier(.alpha2) { return code }
        return raw
    }

    /// dvh1／dvhe（Profile 5、8 的 sample entry），或 hvc1 加上 dvcC／dvvC 設定（Profile 8.1 常見）
    static func isDolbyVision(_ desc: CMFormatDescription) -> Bool {
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(desc))
        if ["dvh1", "dvhe", "dva1", "dvav"].contains(codec) { return true }
        if let atoms = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
            return atoms.keys.contains { ["dvcC", "dvvC", "dvwC"].contains($0) }
        }
        return false
    }

    static func audioName(_ subtype: FourCharCode) -> String {
        switch fourCC(subtype) {
        case "ec-3": "E-AC3"
        case "ac-3": "AC3"
        case "aac ", "mp4a": "AAC"
        case "alac": "ALAC"
        case "lpcm": "PCM"
        case "opus": "Opus"
        case "fLaC": "FLAC"
        case let other: other.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
