import AVFoundation
import CoreMedia
import Foundation

/// 用 AVURLAsset（透過本機代理）讀 track 資訊：解析度、HDR、杜比視界、音訊格式
struct SpecInfo: Sendable {
    var duration: Double = 0
    var width: Int?
    var height: Int?
    var isHDR = false
    var isDolbyVision = false
    var audioFormat: String?
}

enum SpecProbe {
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
            for desc in try await track.load(.formatDescriptions) where isDolbyVision(desc) {
                info.isDolbyVision = true
            }
            break
        }

        for track in try await asset.loadTracks(withMediaType: .audio) {
            if let desc = try await track.load(.formatDescriptions).first {
                info.audioFormat = audioName(CMFormatDescriptionGetMediaSubType(desc))
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
