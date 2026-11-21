import Foundation

/// 讀 MP4／MOV 的盒子（box／atom），給串流代理修正 iPhone 不認得的 sample entry 用。
public enum MP4Boxes {
    public struct Header: Sendable, Equatable {
        public var type: String
        /// 整個盒子的大小（含標頭）；0 表示一直到檔案結尾
        public var size: Int64
        public var headerSize: Int
    }

    /// 讀 offset 位置的盒子標頭（32 位元或 64 位元大小）。bytes 至少要 16 個位元組才能讀 64 位元的
    public static func header(_ bytes: [UInt8], at offset: Int = 0) -> Header? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        let size32 = readUInt32(bytes, offset)
        let typeBytes = bytes[(offset + 4)..<(offset + 8)]
        guard typeBytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        let type = String(decoding: typeBytes, as: UTF8.self)
        if size32 == 1 {
            guard offset + 16 <= bytes.count else { return nil }
            let size64 = (Int64(readUInt32(bytes, offset + 8)) << 32) | Int64(readUInt32(bytes, offset + 12))
            guard size64 >= 16 else { return nil }
            return Header(type: type, size: size64, headerSize: 16)
        }
        if size32 == 0 { return Header(type: type, size: 0, headerSize: 8) }
        guard size32 >= 8 else { return nil }
        return Header(type: type, size: Int64(size32), headerSize: 8)
    }

    /// iPhone 的播放器只認 hvc1／dvh1；hev1／dvhe（ffmpeg 預設）會變成只有聲音、畫面一個 Q。
    /// 參數集通常也放在 hvcC 裡，所以只要改名就能播（跟 `ffmpeg -tag:v hvc1` 一樣）
    public static let sampleEntryRenames: [String: String] = ["hev1": "hvc1", "dvhe": "dvh1"]

    /// 在 moov 的位元組裡找要改名的 sample entry，回傳（相對 moov 開頭的位置, 新的四個字元）
    public static func sampleEntryPatches(inMoov bytes: [UInt8]) -> [(offset: Int, replacement: [UInt8])] {
        var out: [(Int, [UInt8])] = []
        let stsd = Array("stsd".utf8)
        var i = 4
        while i + 12 <= bytes.count {
            if bytes[i] == stsd[0], bytes[i + 1] == stsd[1], bytes[i + 2] == stsd[2], bytes[i + 3] == stsd[3] {
                let boxStart = i - 4
                let boxSize = Int(readUInt32(bytes, boxStart))
                let boxEnd = min(bytes.count, boxStart + max(boxSize, 16))
                let count = Int(readUInt32(bytes, i + 8))
                var p = i + 12
                var n = 0
                while n < count, p + 8 <= boxEnd {
                    let size = Int(readUInt32(bytes, p))
                    let type = String(decoding: bytes[(p + 4)..<(p + 8)], as: UTF8.self)
                    if let newType = sampleEntryRenames[type] {
                        out.append((p + 4, Array(newType.utf8)))
                    }
                    guard size >= 8 else { break }
                    p += size
                    n += 1
                }
                i = max(i + 4, boxEnd)
            } else {
                i += 1
            }
        }
        return out
    }

    /// avcC 的 profile_idc：110（High 10，動畫壓制組常用）、122、244 iPhone 的硬體解碼器不支援
    public static func h264Profile(avcC: [UInt8]) -> Int? {
        guard avcC.count >= 2, avcC[0] == 1 else { return nil }
        return Int(avcC[1])
    }

    public static func isUnsupportedH264Profile(_ profile: Int) -> Bool {
        [110, 122, 244, 44].contains(profile)
    }

    private static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }
}

/// 編碼的顯示名稱（播放器不支援時告訴使用者是哪一種）
public enum CodecNames {
    public static func name(fourCC: String) -> String {
        switch fourCC {
        case "dtsc", "dts ": "DTS"
        case "dtsh": "DTS-HD"
        case "dtsl": "DTS-HD MA"
        case "dtse": "DTS Express"
        case "dtsx": "DTS:X"
        case "mlpa": "TrueHD"
        case "ec-3": "E-AC3"
        case "ac-3": "AC3"
        case "mp4a", "aac ": "AAC"
        case "Opus", "opus": "Opus"
        case "fLaC": "FLAC"
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "dvh1", "dvhe": "杜比視界"
        case "av01": "AV1"
        case "vp09": "VP9"
        case "mp4v": "MPEG-4（Xvid／DivX）"
        case let other: other.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }
}
