import Foundation

/// 簡單的 MP4 盒子樹：只展開改 sample table 需要的容器，其他盒子原封不動保留位元組。
public struct MP4Box: Sendable, Equatable {
    public var type: String
    /// 葉子盒子的內容（不含標頭）；容器是 nil
    public var payload: [UInt8]?
    public var children: [MP4Box]

    public init(type: String, payload: [UInt8]) {
        self.type = type
        self.payload = payload
        children = []
    }

    public init(type: String, children: [MP4Box]) {
        self.type = type
        payload = nil
        self.children = children
    }

    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts"]

    /// 解析一串盒子；格式不對回傳 nil
    public static func parse(_ bytes: ArraySlice<UInt8>) -> [MP4Box]? {
        var out: [MP4Box] = []
        var p = bytes.startIndex
        while p < bytes.endIndex {
            guard p + 8 <= bytes.endIndex else { return nil }
            var size = Int(BE.u32(bytes, p))
            let type = String(decoding: bytes[(p + 4)..<(p + 8)], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard p + 16 <= bytes.endIndex else { return nil }
                size = Int(BE.u64(bytes, p + 8))
                header = 16
            } else if size == 0 {
                size = bytes.endIndex - p
            }
            guard size >= header, p + size <= bytes.endIndex else { return nil }
            let body = bytes[(p + header)..<(p + size)]
            if containers.contains(type) {
                guard let children = parse(body) else { return nil }
                out.append(MP4Box(type: type, children: children))
            } else {
                out.append(MP4Box(type: type, payload: Array(body)))
            }
            p += size
        }
        return out
    }

    public func serialized() -> [UInt8] {
        var out: [UInt8] = []
        write(into: &out)
        return out
    }

    public var size: Int {
        8 + (payload?.count ?? children.reduce(0) { $0 + $1.size })
    }

    func write(into out: inout [UInt8]) {
        BE.put32(&out, UInt32(size))
        out.append(contentsOf: Array(type.utf8.prefix(4)))
        if let payload {
            out.append(contentsOf: payload)
        } else {
            for child in children { child.write(into: &out) }
        }
    }

    public func child(_ type: String) -> MP4Box? { children.first { $0.type == type } }

    /// 用路徑找（"mdia/minf/stbl/stsd"）
    public func find(_ path: String) -> MP4Box? {
        var box: MP4Box? = self
        for part in path.split(separator: "/") { box = box?.child(String(part)) }
        return box
    }
}

// MARK: - Sample table

/// 一條軌的 sample 位置與時間（stts、stsc、stsz、stco／co64）
public struct MP4SampleTable: Sendable {
    public let timescale: Int
    public let sampleCount: Int
    private let constantSize: UInt32
    private let sizes: [UInt32]
    private let chunkOffsets: [Int64]
    /// 每個 chunk 的第一個 sample
    private let chunkFirstSample: [Int]
    private let sttsCounts: [Int]
    private let sttsDeltas: [Int64]
    /// 每個 stts 項目開始的 sample 與時間
    private let sttsFirstSample: [Int]
    private let sttsFirstTime: [Int64]
    /// 全部的長度（媒體時間）
    public let duration: Int64

    public init?(stbl: MP4Box, timescale: Int) {
        guard timescale > 0,
              let stts = stbl.child("stts")?.payload,
              let stsc = stbl.child("stsc")?.payload,
              let stsz = stbl.child("stsz")?.payload,
              let offsets = Self.chunkOffsets(stbl) else { return nil }
        self.timescale = timescale

        // stsz
        guard stsz.count >= 12 else { return nil }
        constantSize = BE.u32(stsz, 4)
        let count = Int(BE.u32(stsz, 8))
        if constantSize == 0 {
            guard stsz.count >= 12 + count * 4 else { return nil }
            var list = [UInt32](repeating: 0, count: count)
            for i in 0..<count { list[i] = BE.u32(stsz, 12 + i * 4) }
            sizes = list
        } else {
            sizes = []
        }
        sampleCount = count
        chunkOffsets = offsets

        // stsc → 每個 chunk 的第一個 sample
        guard stsc.count >= 8 else { return nil }
        let entries = Int(BE.u32(stsc, 4))
        guard stsc.count >= 8 + entries * 12, entries > 0 else { return nil }
        var first = [Int](repeating: 0, count: offsets.count)
        var sample = 0
        for e in 0..<entries {
            let firstChunk = Int(BE.u32(stsc, 8 + e * 12)) - 1
            let perChunk = Int(BE.u32(stsc, 8 + e * 12 + 4))
            let nextChunk = e + 1 < entries ? Int(BE.u32(stsc, 8 + (e + 1) * 12)) - 1 : offsets.count
            guard firstChunk >= 0 else { return nil }
            var c = firstChunk
            while c < min(nextChunk, offsets.count) {
                first[c] = sample
                sample += perChunk
                c += 1
            }
        }
        chunkFirstSample = first

        // stts
        guard stts.count >= 8 else { return nil }
        let sttsEntries = Int(BE.u32(stts, 4))
        guard stts.count >= 8 + sttsEntries * 8 else { return nil }
        var counts: [Int] = [], deltas: [Int64] = [], firstSamples: [Int] = [], firstTimes: [Int64] = []
        var s = 0
        var t: Int64 = 0
        for e in 0..<sttsEntries {
            let c = Int(BE.u32(stts, 8 + e * 8))
            let d = Int64(BE.u32(stts, 8 + e * 8 + 4))
            guard c > 0 else { continue }
            counts.append(c); deltas.append(d); firstSamples.append(s); firstTimes.append(t)
            s += c
            t += Int64(c) * d
        }
        sttsCounts = counts
        sttsDeltas = deltas
        sttsFirstSample = firstSamples
        sttsFirstTime = firstTimes
        duration = t
        guard s >= count else { return nil }
    }

    private static func chunkOffsets(_ stbl: MP4Box) -> [Int64]? {
        if let stco = stbl.child("stco")?.payload, stco.count >= 8 {
            let n = Int(BE.u32(stco, 4))
            guard stco.count >= 8 + n * 4 else { return nil }
            return (0..<n).map { Int64(BE.u32(stco, 8 + $0 * 4)) }
        }
        if let co64 = stbl.child("co64")?.payload, co64.count >= 8 {
            let n = Int(BE.u32(co64, 4))
            guard co64.count >= 8 + n * 8 else { return nil }
            return (0..<n).map { Int64(bitPattern: BE.u64(co64, 8 + $0 * 8)) }
        }
        return nil
    }

    public func size(of sample: Int) -> Int {
        Int(constantSize != 0 ? constantSize : sizes[sample])
    }

    /// 一段連續 sample 在檔案裡的位置
    public func locations(_ range: Range<Int>) -> [(offset: Int64, size: Int)] {
        guard !range.isEmpty else { return [] }
        var out: [(Int64, Int)] = []
        out.reserveCapacity(range.count)
        var chunk = chunkIndex(of: range.lowerBound)
        var offset = chunkOffsets[chunk]
        for s in chunkFirstSample[chunk]..<range.lowerBound { offset += Int64(size(of: s)) }
        for s in range {
            while chunk + 1 < chunkFirstSample.count, chunkFirstSample[chunk + 1] <= s {
                chunk += 1
                offset = chunkOffsets[chunk]
            }
            let n = size(of: s)
            out.append((offset, n))
            offset += Int64(n)
        }
        return out
    }

    private func chunkIndex(of sample: Int) -> Int {
        var lo = 0, hi = chunkFirstSample.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if chunkFirstSample[mid] <= sample { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// sample 開始的媒體時間
    public func time(of sample: Int) -> Int64 {
        guard sample < sampleCount else { return duration }
        let e = entry(containing: sample)
        return sttsFirstTime[e] + Int64(sample - sttsFirstSample[e]) * sttsDeltas[e]
    }

    /// 包含這個媒體時間的 sample
    public func sample(at time: Int64) -> Int {
        guard time > 0 else { return 0 }
        guard time < duration else { return sampleCount }
        var lo = 0, hi = sttsFirstTime.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if sttsFirstTime[mid] <= time { lo = mid } else { hi = mid - 1 }
        }
        let delta = max(sttsDeltas[lo], 1)
        let within = Int((time - sttsFirstTime[lo]) / delta)
        return min(sttsFirstSample[lo] + min(within, sttsCounts[lo] - 1), sampleCount - 1)
    }

    private func entry(containing sample: Int) -> Int {
        var lo = 0, hi = sttsFirstSample.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if sttsFirstSample[mid] <= sample { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

// MARK: - 大端序

enum BE {
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    static func u32(_ b: ArraySlice<UInt8>, _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (UInt64(u32(b, o)) << 32) | UInt64(u32(b, o + 4))
    }

    static func u64(_ b: ArraySlice<UInt8>, _ o: Int) -> UInt64 {
        (UInt64(u32(b, o)) << 32) | UInt64(u32(b, o + 4))
    }

    static func put16(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(v >> 8)); out.append(UInt8(v & 0xFF))
    }

    static func put32(_ out: inout [UInt8], _ v: UInt32) {
        for s in stride(from: 24, through: 0, by: -8) { out.append(UInt8((v >> UInt32(s)) & 0xFF)) }
    }

    static func put64(_ out: inout [UInt8], _ v: UInt64) {
        for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((v >> UInt64(s)) & 0xFF)) }
    }

    static func set32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        for i in 0..<4 { b[o + i] = UInt8((v >> UInt32(24 - i * 8)) & 0xFF) }
    }

    static func set64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
        for i in 0..<8 { b[o + i] = UInt8((v >> UInt64(56 - i * 8)) & 0xFF) }
    }
}
