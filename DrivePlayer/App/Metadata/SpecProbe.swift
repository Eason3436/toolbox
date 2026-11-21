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
}

enum SpecProbe {
    /// 讀到的欄位變多就加 1，舊的會在開詳細頁時重讀（2：聲道、全景聲、HDR 種類）
    static let version = 2

    static func probe(url: URL) async throws -> SpecInfo {
        let asset = AVURLAsset(url: url)
        var info = SpecInfo()
        let duration = try await asset.load(.duration)
        if duration.seconds.isFinite { info.duration = duration.seconds }

        for track in try await asset.loadTracks(withMediaType: .video) {
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

        for track in try await asset.loadTracks(withMediaType: .audio) {
            if let desc = try await track.load(.formatDescriptions).first {
                let subtype = fourCC(CMFormatDescriptionGetMediaSubType(desc))
                info.audioFormat = audioName(CMFormatDescriptionGetMediaSubType(desc))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee, asbd.mChannelsPerFrame > 0 {
                    info.audioChannels = Int(asbd.mChannelsPerFrame)
                }
                // 杜比的設定盒比 ASBD 準（E-AC3 7.1、全景聲 JOC）
                if let atoms = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
                    if subtype == "ec-3", let data = atoms["dec3"] as? Data, let dolby = DolbyAudioConfig.parseDEC3([UInt8](data)) {
                        info.audioChannels = dolby.channels
                        info.isAtmos = dolby.isAtmos
                    } else if subtype == "ac-3", let data = atoms["dac3"] as? Data, let dolby = DolbyAudioConfig.parseDAC3([UInt8](data)) {
                        info.audioChannels = dolby.channels
                    }
                }
            }
            break
        }
        return info
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
