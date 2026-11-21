import Foundation

/// 杜比音訊的設定盒（MP4 sample entry 裡的 dac3／dec3）：聲道數、是不是全景聲
public enum DolbyAudioConfig {
    public struct Info: Equatable, Sendable {
        /// 含 LFE 的總聲道數（5.1 = 6）
        public var channels: Int
        public var hasLFE: Bool
        /// E-AC3 JOC（串流版杜比全景聲）
        public var isAtmos: Bool
    }

    /// acmod → 主聲道數（不含 LFE）
    private static let acmodChannels = [2, 1, 2, 3, 3, 4, 4, 5]
    /// dec3 的 chan_loc（9 bit，從高位元起）：Lc/Rc、Lrs/Rrs、Cs、Ts、Lsd/Rsd、Lw/Rw、Lvh/Rvh、Cvh、LFE2
    private static let chanLocWeights = [2, 2, 1, 1, 2, 2, 2, 1, 1]

    /// AC-3 的 dac3：fscod(2) bsid(5) bsmod(3) acmod(3) lfeon(1)
    public static func parseDAC3(_ data: [UInt8]) -> Info? {
        var r = BitReader(data)
        guard r.skip(2 + 5 + 3), let acmod = r.read(3), let lfe = r.read(1) else { return nil }
        let main = acmodChannels[acmod]
        return Info(channels: main + lfe, hasLFE: lfe == 1, isAtmos: false)
    }

    /// E-AC3 的 dec3（ETSI TS 102 366 附錄 F）
    public static func parseDEC3(_ data: [UInt8]) -> Info? {
        var r = BitReader(data)
        guard r.skip(13), let numIndSub = r.read(3) else { return nil }
        var channels = 0
        var hasLFE = false
        for index in 0...numIndSub {
            guard r.skip(2 + 5 + 1 + 1 + 3), let acmod = r.read(3), let lfe = r.read(1),
                  r.skip(3), let numDepSub = r.read(4) else { return nil }
            var extra = 0
            if numDepSub > 0 {
                guard let chanLoc = r.read(9) else { return nil }
                for bit in 0..<9 where chanLoc & (1 << (8 - bit)) != 0 {
                    extra += chanLocWeights[bit]
                }
            } else {
                guard r.skip(1) else { return nil }
            }
            // 第一個獨立子串流才是主節目
            if index == 0 {
                channels = acmodChannels[acmod] + lfe + extra
                hasLFE = lfe == 1
            }
        }
        var atmos = false
        if r.skip(7), let flag = r.read(1), flag == 1 { atmos = true }
        return Info(channels: channels, hasLFE: hasLFE, isAtmos: atmos)
    }

    /// 「5.1」「7.1」「立體聲」
    public static func layoutName(channels: Int) -> String? {
        switch channels {
        case ..<1: return nil
        case 1: return "單聲道"
        case 2: return "立體聲"
        case 3: return "2.1"
        case 4: return "4.0"
        case 5: return "5.0"
        default: return "\(channels - 1).1"
        }
    }
}

struct BitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int? {
        guard position + count <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            let byte = bytes[position / 8]
            let bit = (byte >> (7 - UInt8(position % 8))) & 1
            value = (value << 1) | Int(bit)
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) -> Bool {
        guard position + count <= bytes.count * 8 else { return false }
        position += count
        return true
    }
}
