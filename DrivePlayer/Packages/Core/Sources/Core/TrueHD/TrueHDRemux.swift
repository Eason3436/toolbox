import Foundation

/// 把 MP4 裡 iPhone 解不了的 TrueHD 音軌，換成串流代理邊播邊解出來的 PCM 音軌。
///
/// 播放器看到的「虛擬檔案」：
/// ```
/// [原檔（ftyp 改成 QuickTime、原本的 moov 改名成 free）][新的 moov][mdat 標頭][PCM]
/// ```
/// 影片 sample 的位置都沒動，所以影片照原檔讀；新的 moov 裡 TrueHD 那條軌改成 lpcm，
/// sample 指到最後面的 PCM 區。播放器讀 PCM 區時，代理找出對應的 TrueHD sample、解碼、送出。
public enum TrueHDRemux {

    /// TrueHD 音軌
    public struct Track: Sendable {
        /// moov 裡第幾個 trak
        public let index: Int
        /// tkhd 的 track ID
        public let trackID: Int
        public let table: MP4SampleTable
    }

    /// moov 裡所有的 TrueHD 音軌
    public struct Tracks: Sendable {
        public let tracks: [Track]
        /// 解析好的 moov（做計畫時用，不用再解析一次）
        let moov: MP4Box
    }

    /// 找出要轉換的 TrueHD 音軌（全部都轉，旁邊有能播的音軌也一樣，才能切換）。沒有或是 fragmented MP4 回傳 nil
    public static func findTracks(moov: [UInt8]) -> Tracks? {
        guard let top = MP4Box.parse(moov[...]), let moovBox = top.first, moovBox.type == "moov",
              moovBox.child("mvex") == nil else { return nil }
        var found: [Track] = []
        for (index, trak) in moovBox.children.enumerated() where trak.type == "trak" {
            guard let hdlr = trak.find("mdia/hdlr")?.payload, hdlr.count >= 12,
                  String(decoding: hdlr[8..<12], as: UTF8.self) == "soun",
                  sampleEntryType(trak) == "mlpa",
                  let trackID = trackID(trak),
                  let stbl = trak.find("mdia/minf/stbl"),
                  let timescale = mediaTimescale(trak),
                  let table = MP4SampleTable(stbl: stbl, timescale: timescale),
                  table.sampleCount > 0 else { continue }
            found.append(Track(index: index, trackID: trackID, table: table))
        }
        return found.isEmpty ? nil : Tracks(tracks: found, moov: moovBox)
    }

    static func trackID(_ trak: MP4Box) -> Int? {
        guard let tkhd = trak.child("tkhd")?.payload, tkhd.count >= 24 else { return nil }
        return Int(BE.u32(tkhd, tkhd[0] == 1 ? 20 : 12))
    }

    static func sampleEntryType(_ trak: MP4Box) -> String? {
        guard let stsd = trak.find("mdia/minf/stbl/stsd")?.payload, stsd.count >= 16 else { return nil }
        return String(decoding: stsd[12..<16], as: UTF8.self)
    }

    static func mediaTimescale(_ trak: MP4Box) -> Int? {
        guard let mdhd = trak.find("mdia/mdhd")?.payload, mdhd.count >= 24 else { return nil }
        return Int(BE.u32(mdhd, mdhd[0] == 1 ? 20 : 12))
    }

    /// 頂層盒子（位置、大小）
    public struct TopLevelBox: Sendable {
        public var type: String
        public var offset: Int64
        public var size: Int64
        public init(type: String, offset: Int64, size: Int64) {
            self.type = type
            self.offset = offset
            self.size = size
        }
    }

    /// 一個 PCM chunk 幾個取樣格（0.5 秒左右）
    public static let framesPerChunk = 24000

    /// 做好轉換計畫。`formats` 是每條音軌解出來的格式（解不出來的放 nil，那條就不轉）。
    /// 檔案結構不支援（最後一個盒子大小寫 0、找不到 ftyp）或一條都不能轉就回傳 nil
    public static func plan(tracks: Tracks, formats: [TrueHDFormat?], topLevel: [TopLevelBox],
                            fileSize: Int64) -> TrueHDRemuxPlan? {
        // 後面要接新的盒子：原檔的盒子要剛好排到檔尾（沒有「大小 0＝到檔尾」）
        guard let moovEntry = topLevel.first(where: { $0.type == "moov" }),
              let ftyp = topLevel.first(where: { $0.type == "ftyp" }), ftyp.size >= 12,
              topLevel.allSatisfy({ $0.size > 0 }),
              let last = topLevel.last, last.offset + last.size == fileSize,
              formats.count == tracks.tracks.count else { return nil }

        struct Pending {
            let track: Track
            let format: TrueHDFormat
            let totalFrames: Int64
            let bytesPerFrame: Int
            /// 在 PCM 區裡的位置
            let relativeStart: Int64
        }
        var pending: [Pending] = []
        var pcmBytes: Int64 = 0
        for (track, format) in zip(tracks.tracks, formats) {
            guard let format, format.sampleRate > 0, format.channels > 0 else { continue }
            let table = track.table
            let totalFrames = table.duration * Int64(format.sampleRate) / Int64(table.timescale)
            guard totalFrames > 0, totalFrames < Int64(UInt32.max) else { continue }
            let bytesPerFrame = format.channels * 3
            pending.append(Pending(track: track, format: format, totalFrames: totalFrames,
                                   bytesPerFrame: bytesPerFrame, relativeStart: pcmBytes))
            pcmBytes += totalFrames * Int64(bytesPerFrame)
        }
        guard !pending.isEmpty else { return nil }

        let fpc = Int64(framesPerChunk)
        // 新的 moov 大小跟 co64 的位置有關、co64 又要知道 moov 多大：先用 0 算大小，再填
        func buildMoov(pcmStart: Int64) -> [UInt8] {
            var movie = tracks.moov
            for p in pending {
                let totalFrames = p.totalFrames
                let chunkCount = Int((totalFrames + fpc - 1) / fpc)
                let start = pcmStart + p.relativeStart
                let stbl = MP4Box(type: "stbl", children: [
                    MP4Box(type: "stsd", payload: stsd(format: p.format)),
                    MP4Box(type: "stts", payload: fullBox { o in
                        BE.put32(&o, 1); BE.put32(&o, UInt32(totalFrames)); BE.put32(&o, 1)
                    }),
                    MP4Box(type: "stsc", payload: fullBox { o in
                        let rem = totalFrames % fpc
                        let full = Int(totalFrames / fpc)
                        if rem == 0 || full == 0 {
                            BE.put32(&o, 1)
                            BE.put32(&o, 1); BE.put32(&o, UInt32(full == 0 ? rem : fpc)); BE.put32(&o, 1)
                        } else {
                            BE.put32(&o, 2)
                            BE.put32(&o, 1); BE.put32(&o, UInt32(fpc)); BE.put32(&o, 1)
                            BE.put32(&o, UInt32(full + 1)); BE.put32(&o, UInt32(rem)); BE.put32(&o, 1)
                        }
                    }),
                    MP4Box(type: "stsz", payload: fullBox { o in
                        BE.put32(&o, UInt32(p.bytesPerFrame)); BE.put32(&o, UInt32(totalFrames))
                    }),
                    MP4Box(type: "co64", payload: fullBox { o in
                        BE.put32(&o, UInt32(chunkCount))
                        for c in 0..<chunkCount {
                            BE.put64(&o, UInt64(start + Int64(c) * fpc * Int64(p.bytesPerFrame)))
                        }
                    }),
                ])
                var copy = movie.children[p.track.index]
                replace(&copy, path: ["mdia", "minf", "stbl"], with: stbl)
                if p.track.table.timescale != p.format.sampleRate {
                    rescaleMedia(&copy, from: p.track.table.timescale, to: p.format.sampleRate)
                }
                movie.children[p.track.index] = copy
            }
            return movie.serialized()
        }

        let probe = buildMoov(pcmStart: 0)
        let moovStart = fileSize
        let mdatStart = moovStart + Int64(probe.count)
        let pcmStart = mdatStart + 16
        let newMoov = buildMoov(pcmStart: pcmStart)
        guard newMoov.count == probe.count else { return nil }

        var header = newMoov
        BE.put32(&header, 1)
        header.append(contentsOf: Array("mdat".utf8))
        BE.put64(&header, UInt64(16 + pcmBytes))

        // 原本的 moov 改名成 free；ftyp 的主品牌改成 QuickTime（lpcm 是 QuickTime 的格式）
        var patches: [Int64: UInt8] = [:]
        for (i, byte) in "free".utf8.enumerated() { patches[moovEntry.offset + 4 + Int64(i)] = byte }
        for (i, byte) in "qt  ".utf8.enumerated() { patches[ftyp.offset + 8 + Int64(i)] = byte }

        let planned = pending.map {
            TrueHDTrackPlan(trackID: $0.track.trackID, pcmStart: pcmStart + $0.relativeStart,
                            bytesPerFrame: $0.bytesPerFrame, totalFrames: $0.totalFrames,
                            format: $0.format, table: $0.track.table)
        }
        return TrueHDRemuxPlan(originalSize: fileSize, header: header, patches: patches,
                               tracks: planned, totalSize: pcmStart + pcmBytes)
    }

    private static func fullBox(_ body: (inout [UInt8]) -> Void) -> [UInt8] {
        var out: [UInt8] = [0, 0, 0, 0]
        body(&out)
        return out
    }

    private static func replace(_ box: inout MP4Box, path: ArraySlice<String>, with new: MP4Box) {
        guard let first = path.first, let i = box.children.firstIndex(where: { $0.type == first }) else { return }
        if path.count == 1 {
            box.children[i] = new
        } else {
            replace(&box.children[i], path: path.dropFirst(), with: new)
        }
    }

    /// 媒體時間單位改成取樣率：mdhd 的 timescale／duration、elst 的 media_time
    private static func rescaleMedia(_ trak: inout MP4Box, from old: Int, to new: Int) {
        func scale(_ v: Int64) -> Int64 { v * Int64(new) / Int64(old) }
        if let i = trak.children.firstIndex(where: { $0.type == "mdia" }),
           let j = trak.children[i].children.firstIndex(where: { $0.type == "mdhd" }),
           var p = trak.children[i].children[j].payload {
            if p[0] == 1, p.count >= 32 {
                BE.set32(&p, 20, UInt32(new))
                BE.set64(&p, 24, UInt64(scale(Int64(BE.u64(p, 24)))))
            } else if p.count >= 20 {
                BE.set32(&p, 12, UInt32(new))
                BE.set32(&p, 16, UInt32(truncatingIfNeeded: scale(Int64(BE.u32(p, 16)))))
            }
            trak.children[i].children[j].payload = p
        }
        if let i = trak.children.firstIndex(where: { $0.type == "edts" }),
           let j = trak.children[i].children.firstIndex(where: { $0.type == "elst" }),
           var p = trak.children[i].children[j].payload, p.count >= 8 {
            let v1 = p[0] == 1
            let count = Int(BE.u32(p, 4))
            let entrySize = v1 ? 20 : 12
            for e in 0..<count where 8 + (e + 1) * entrySize <= p.count {
                let o = 8 + e * entrySize + (v1 ? 8 : 4)
                if v1 {
                    let t = Int64(bitPattern: BE.u64(p, o))
                    if t >= 0 { BE.set64(&p, o, UInt64(scale(t))) }
                } else {
                    let t = Int32(bitPattern: BE.u32(p, o))
                    if t >= 0 { BE.set32(&p, o, UInt32(scale(Int64(t)))) }
                }
            }
            trak.children[i].children[j].payload = p
        }
    }

    /// QuickTime 的 SoundDescription V2（lpcm，24-bit 有號整數、little-endian）＋聲道配置
    static func stsd(format: TrueHDFormat) -> [UInt8] {
        var entry: [UInt8] = []
        entry.append(contentsOf: [0, 0, 0, 0, 0, 0]) // reserved
        BE.put16(&entry, 1) // data reference index
        BE.put16(&entry, 2) // version
        BE.put16(&entry, 0) // revision
        BE.put32(&entry, 0) // vendor
        BE.put16(&entry, 3) // always 3
        BE.put16(&entry, 16) // always 16
        BE.put16(&entry, 0xFFFE) // always -2
        BE.put16(&entry, 0) // always 0
        BE.put32(&entry, 0x0001_0000) // always 65536
        BE.put32(&entry, 72) // sizeOfStructOnly
        BE.put64(&entry, Double(format.sampleRate).bitPattern)
        BE.put32(&entry, UInt32(format.channels))
        BE.put32(&entry, 0x7F00_0000)
        BE.put32(&entry, 24) // bits per channel
        BE.put32(&entry, 0x4 | 0x8) // signed integer | packed
        BE.put32(&entry, UInt32(format.channels * 3)) // bytes per packet
        BE.put32(&entry, 1) // frames per packet
        entry.append(contentsOf: MP4Box(type: "chan", payload: chan(mask: format.channelMask)).serialized())

        var out: [UInt8] = [0, 0, 0, 0]
        BE.put32(&out, 1)
        out.append(contentsOf: MP4Box(type: "lpcm", payload: entry).serialized())
        return out
    }

    /// CoreAudio 的 AudioChannelLayout（用聲道描述，順序跟 PCM 一樣）
    static func chan(mask: UInt64) -> [UInt8] {
        let labels = channelLabels(mask: mask)
        var out: [UInt8] = [0, 0, 0, 0]
        BE.put32(&out, 0) // kAudioChannelLayoutTag_UseChannelDescriptions
        BE.put32(&out, 0) // bitmap
        BE.put32(&out, UInt32(labels.count))
        for label in labels {
            BE.put32(&out, label)
            BE.put32(&out, 0) // flags
            for _ in 0..<3 { BE.put32(&out, 0) } // coordinates
        }
        return out
    }

    /// FFmpeg 聲道位元 → CoreAudio 的 kAudioChannelLabel
    static func channelLabels(mask: UInt64) -> [UInt32] {
        let hasSide = mask & (AVCh.sl | AVCh.sr) != 0
        var out: [UInt32] = []
        for bit in 0..<64 where mask & (UInt64(1) << UInt64(bit)) != 0 {
            switch bit {
            case 0...3: out.append(UInt32(bit + 1)) // L R C LFE
            case 4: out.append(hasSide ? 33 : 5) // 後環繞：7.1 是 Rls，5.1(back) 是 Ls
            case 5: out.append(hasSide ? 34 : 6)
            case 6, 7, 8: out.append(UInt32(bit + 1)) // Lc Rc Cs
            case 9: out.append(5) // 側環繞 → Ls
            case 10: out.append(6)
            case 11...17: out.append(UInt32(bit + 1)) // Ts Vhl Vhc Vhr Tbl Tbc Tbr
            case 31: out.append(35) // Lw
            case 32: out.append(36) // Rw
            case 33: out.append(10) // Lsd
            case 34: out.append(11) // Rsd
            case 35: out.append(37) // LFE2
            default: out.append(0) // 不知道
            }
        }
        return out
    }
}

/// 轉換計畫：虛擬檔案的版面
public struct TrueHDRemuxPlan: Sendable {
    /// 原檔大小（虛擬檔案這個位置之後是新的 moov）
    public let originalSize: Int64
    /// 新的 moov＋PCM 的 mdat 標頭
    public let header: [UInt8]
    /// 原檔要改的位元組
    public let patches: [Int64: UInt8]
    /// 轉換的音軌，PCM 依序排在最後面的 mdat 裡
    public let tracks: [TrueHDTrackPlan]
    public let totalSize: Int64

    /// PCM 區從哪裡開始
    public var pcmStart: Int64 { tracks[0].pcmStart }

    /// 包含這個位置的音軌
    public func track(containing offset: Int64) -> TrueHDTrackPlan? {
        tracks.first { $0.pcmStart <= offset && offset < $0.pcmEnd }
    }
}

/// 一條 TrueHD 音軌轉成的 PCM
public struct TrueHDTrackPlan: Sendable {
    public let trackID: Int
    /// 這條音軌的 PCM 從哪裡開始（虛擬檔案裡的位置）
    public let pcmStart: Int64
    public let bytesPerFrame: Int
    public let totalFrames: Int64
    public let format: TrueHDFormat
    public let table: MP4SampleTable

    public var pcmEnd: Int64 { pcmStart + totalFrames * Int64(bytesPerFrame) }

    /// TrueHD sample 開始的取樣格
    public func frame(ofSample sample: Int) -> Int64 {
        table.time(of: sample) * Int64(format.sampleRate) / Int64(table.timescale)
    }

    /// 包含這個取樣格的 TrueHD sample
    public func sample(containingFrame target: Int64) -> Int {
        var s = table.sample(at: target * Int64(table.timescale) / Int64(format.sampleRate))
        // 時間單位不同時可能差一個
        while s > 0, frame(ofSample: s) > target { s -= 1 }
        while s + 1 < table.sampleCount, frame(ofSample: s + 1) <= target { s += 1 }
        return s
    }
}

/// 把 TrueHD sample 解成 PCM 位元組。記得上次解到哪裡：播放器照順序讀時接著解，跳位置時往前退一段再開始解
/// （要從 major sync 開始才解得出來）。
public final class TrueHDPCMRenderer {
    public let plan: TrueHDTrackPlan
    private let decoder = TrueHDDecoder()
    /// 下一個要解的 sample（解碼器狀態接得上）
    private var cursor = -1
    /// 最近解好的 sample 的 PCM（請求的邊界常常切在 sample 中間）
    private var recent: [Int: [UInt8]] = [:]
    private var recentOrder: [Int] = []

    /// 跳位置時往前多解幾個 AU，確定碰到 major sync
    static let prerollAccessUnits = 256
    /// 跳位置時往前退幾個 sample
    private let preroll: Int

    public init(plan: TrueHDTrackPlan) {
        self.plan = plan
        let unitsPerSample = max(1, Int(plan.frame(ofSample: 1) - plan.frame(ofSample: 0)) / max(plan.format.accessUnitSize, 1))
        preroll = max(1, Self.prerollAccessUnits / unitsPerSample)
    }

    /// 這段 PCM（相對這條音軌 PCM 開頭的位元組範圍）需要解哪些 TrueHD sample；空的表示都解過了
    public func samplesNeeded(for range: Range<Int64>) -> Range<Int> {
        let (first, last) = sampleSpan(range)
        guard let missing = (first...last).first(where: { recent[$0] == nil }) else { return cursor..<cursor }
        // 解碼器接得上就接著解，不然往前退一段重新開始
        if cursor >= 0, cursor <= missing, cursor >= missing - preroll { return cursor..<(last + 1) }
        return max(0, missing - preroll)..<(last + 1)
    }

    private func sampleSpan(_ range: Range<Int64>) -> (Int, Int) {
        let bpf = Int64(plan.bytesPerFrame)
        let f0 = min(range.lowerBound / bpf, plan.totalFrames - 1)
        let f1 = min(max(f0, (range.upperBound - 1) / bpf), plan.totalFrames - 1)
        return (plan.sample(containingFrame: f0), plan.sample(containingFrame: f1))
    }

    /// 解碼並回傳這段 PCM。`samples` 是 `samplesNeeded` 那個範圍的 TrueHD 資料（依序）
    public func render(_ range: Range<Int64>, samples: [[UInt8]], startingAt start: Int) -> [UInt8] {
        let (first, last) = sampleSpan(range)
        if !samples.isEmpty, start != cursor {
            decoder.reset()
        }
        for (i, data) in samples.enumerated() {
            let index = start + i
            let pcm = decodeSample(data, index: index)
            if index >= first { remember(index, pcm) }
        }
        if !samples.isEmpty { cursor = start + samples.count }

        // 把需要的 sample 串起來，切出要的位元組
        let bpf = Int64(plan.bytesPerFrame)
        let base = plan.frame(ofSample: first) * bpf
        var out: [UInt8] = []
        out.reserveCapacity(Int(range.count))
        for s in first...last {
            if let pcm = recent[s] {
                out.append(contentsOf: pcm)
            } else {
                out.append(contentsOf: [UInt8](repeating: 0, count: expectedFrames(s) * plan.bytesPerFrame))
            }
        }
        let lo = Int(range.lowerBound - base)
        let hi = min(out.count, lo + range.count)
        guard lo >= 0, lo <= hi else { return [UInt8](repeating: 0, count: range.count) }
        var slice = Array(out[lo..<hi])
        if slice.count < range.count { slice.append(contentsOf: [UInt8](repeating: 0, count: range.count - slice.count)) }
        return slice
    }

    private func expectedFrames(_ sample: Int) -> Int {
        Int(plan.frame(ofSample: sample + 1) - plan.frame(ofSample: sample))
    }

    private func remember(_ index: Int, _ pcm: [UInt8]) {
        if recent[index] == nil { recentOrder.append(index) }
        recent[index] = pcm
        while recentOrder.count > 4096 {
            recent[recentOrder.removeFirst()] = nil
        }
    }

    /// 解一個 MP4 sample（可能包含好幾個 AU），長度補齊或切到 sample 該有的取樣格數
    private func decodeSample(_ data: [UInt8], index: Int) -> [UInt8] {
        let format = plan.format
        let channels = format.channels
        let expected = expectedFrames(index)
        var pcm = [UInt8](repeating: 0, count: expected * plan.bytesPerFrame)
        var written = 0
        for range in TrueHDDecoder.accessUnits(in: data) {
            guard let frames = decoder.decode(data[range]) else {
                written += format.accessUnitSize
                continue
            }
            let outMask = decoder.format?.channelMask ?? format.channelMask
            let decodedChannels = outMask.nonzeroBitCount
            // 聲道配置不一樣時（少見）照位元對應，沒有的補 0
            let map: [Int?]
            if outMask == format.channelMask {
                map = Array(0..<channels)
            } else {
                map = (0..<64).filter { format.channelMask & (UInt64(1) << UInt64($0)) != 0 }.map { bit -> Int? in
                    guard outMask & (UInt64(1) << UInt64(bit)) != 0 else { return nil }
                    return (outMask & ((UInt64(1) << UInt64(bit)) - 1)).nonzeroBitCount
                }
            }
            let output = decoder.output
            for f in 0..<frames where written + f < expected {
                var p = (written + f) * plan.bytesPerFrame
                for ch in 0..<channels {
                    let v = map[ch].map { output[f * decodedChannels + $0] } ?? 0
                    pcm[p] = UInt8(truncatingIfNeeded: v)
                    pcm[p + 1] = UInt8(truncatingIfNeeded: v >> 8)
                    pcm[p + 2] = UInt8(truncatingIfNeeded: v >> 16)
                    p += 3
                }
            }
            written += frames
        }
        return pcm
    }
}
