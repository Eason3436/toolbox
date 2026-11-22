// Dolby TrueHD（MLP）解碼器。
//
// 照 FFmpeg 的 libavcodec/mlpdec.c、mlpdsp.c、mlp.c、mlp_parse.c 移植成 Swift
// （原作者 Ian Caulfield 等，LGPL-2.1 以上；這個檔案沿用同一個授權）。
// 只做播放需要的部分：TrueHD（0xBA）、最多解到第 3 個子串流（全景聲的 7.1 底層），
// 不檢查 CRC／checksum、不做降混。輸出 24-bit 整數 PCM，聲道照 FFmpeg 的原生順序
// （FL FR FC LFE BL BR FLC FRC BC SL SR …，跟 WAVE／CoreAudio 的 bitmap 一樣）。

/// 解出來的串流格式
public struct TrueHDFormat: Equatable, Sendable {
    public var sampleRate: Int
    /// 聲道遮罩（FFmpeg 的 AV_CH_* 位元）
    public var channelMask: UInt64
    /// 一個 access unit 幾個取樣（48 kHz 是 40）
    public var accessUnitSize: Int
    /// 有杜比全景聲的延伸子串流（這裡只解 7.1 底層）
    public var isAtmos: Bool

    public var channels: Int { channelMask.nonzeroBitCount }
}

public final class TrueHDDecoder {
    // MARK: 常數（mlp.h）

    static let maxChannels = 8
    static let maxMatrixChannelTrueHD = 7
    static let maxMatrixChannelMLP = 5
    static let maxMatrices = 8
    static let maxSubstreams = 4
    static let maxBlocksize = 160
    static let maxBlocksizePow2 = 256
    static let maxFIROrder = 8
    static let maxIIROrder = 4

    static let paramBlocksize: UInt8 = 1 << 7
    static let paramMatrix: UInt8 = 1 << 6
    static let paramOutshift: UInt8 = 1 << 5
    static let paramQuantstep: UInt8 = 1 << 4
    static let paramFIR: UInt8 = 1 << 3
    static let paramIIR: UInt8 = 1 << 2
    static let paramHuffOffset: UInt8 = 1 << 1
    static let paramPresence: UInt8 = 1 << 0

    // MARK: 狀態

    struct ChannelParams {
        var firOrder = 0
        var firShift = 0
        var iirOrder = 0
        var iirShift = 0
        var firState = [Int32](repeating: 0, count: TrueHDDecoder.maxFIROrder)
        var iirState = [Int32](repeating: 0, count: TrueHDDecoder.maxFIROrder)
        var firCoeff = [Int32](repeating: 0, count: TrueHDDecoder.maxFIROrder)
        var iirCoeff = [Int32](repeating: 0, count: TrueHDDecoder.maxFIROrder)
        var huffOffset: Int32 = 0
        var signHuffOffset: Int32 = 0
        var codebook = 0
        var huffLsbs = 0
    }

    final class SubStream {
        var restartSeen = false
        var endOfStream = false
        var noiseType = false
        var minChannel = 0
        var maxChannel = 0
        var codedChannels: UInt64 = 0
        var maxMatrixChannel = 0
        var chAssign = [Int](repeating: 0, count: TrueHDDecoder.maxChannels)
        var mask: UInt64 = 0
        var channelParams = [ChannelParams](repeating: ChannelParams(), count: TrueHDDecoder.maxChannels)
        var noiseShift = 0
        var noisegenSeed: UInt32 = 0
        var dataCheckPresent = false
        var paramPresenceFlags: UInt8 = 0
        var numPrimitiveMatrices = 0
        var matrixOutCh = [Int](repeating: 0, count: TrueHDDecoder.maxMatrices)
        var lsbBypass = [Bool](repeating: false, count: TrueHDDecoder.maxMatrices)
        /// [矩陣][聲道]，2.14 定點
        var matrixCoeff = [Int32](repeating: 0, count: TrueHDDecoder.maxMatrices * TrueHDDecoder.maxChannels)
        var matrixNoiseShift = [Int](repeating: 0, count: TrueHDDecoder.maxMatrices)
        var quantStepSize = [Int](repeating: 0, count: TrueHDDecoder.maxChannels)
        var blocksize = 0
        var blockpos = 0
        var outputShift = [Int](repeating: 0, count: TrueHDDecoder.maxChannels)
    }

    private var paramsValid = false
    private var majorSyncHeaderSize = 0
    private var numSubstreams = 0
    private var substreamInfo = 0
    private var maxDecodedSubstream = 0
    private var accessUnitSize = 0
    private var accessUnitSizePow2 = 0
    private var sampleRate = 0
    private var isAtmos = false
    /// 目前輸出的聲道數（FFmpeg 的 avctx->ch_layout.nb_channels）
    private var outputChannels = 0
    private var outputMask: UInt64 = 0

    private var substreams = (0..<TrueHDDecoder.maxSubstreams).map { _ in SubStream() }
    private var matrixChanged = 0
    private var filterChanged = [Int](repeating: 0, count: TrueHDDecoder.maxChannels * 2)

    private var noiseBuffer = [Int8](repeating: 0, count: TrueHDDecoder.maxBlocksizePow2)
    /// [取樣][矩陣]
    private var bypassedLsbs = [UInt8](repeating: 0, count: TrueHDDecoder.maxBlocksize * TrueHDDecoder.maxChannels)
    /// [取樣][聲道]
    private var sampleBuffer = [Int32](repeating: 0, count: TrueHDDecoder.maxBlocksize * TrueHDDecoder.maxChannels)
    private var firScratch = [Int32](repeating: 0, count: TrueHDDecoder.maxBlocksize + TrueHDDecoder.maxFIROrder)
    private var iirScratch = [Int32](repeating: 0, count: TrueHDDecoder.maxBlocksize + TrueHDDecoder.maxFIROrder)

    /// 上一個 access unit 解出來的 PCM（交錯，每個值是 24-bit 有號整數）
    public private(set) var output: [Int32] = []
    /// 上一個 access unit 的格式
    public private(set) var format: TrueHDFormat?

    public init() {}

    /// 從頭開始（換位置播放時）
    public func reset() {
        paramsValid = false
        for s in substreams { s.restartSeen = false; s.endOfStream = false }
    }

    /// 把一個 MP4 sample 拆成 access unit（每個 AU 開頭兩個位元組的低 12 位元是長度／2）
    public static func accessUnits(in bytes: [UInt8]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var p = 0
        while p + 4 <= bytes.count {
            let length = (Int(bytes[p] & 0x0F) << 8 | Int(bytes[p + 1])) * 2
            guard length >= 4, p + length <= bytes.count else { break }
            out.append(p..<(p + length))
            p += length
        }
        return out
    }

    /// 這個 AU 開頭是不是 major sync（可以從這裡開始解）
    public static func isMajorSync(_ au: ArraySlice<UInt8>) -> Bool {
        guard au.count >= 8 else { return false }
        let b = au.startIndex + 4
        return au[b] == 0xF8 && au[b + 1] == 0x72 && au[b + 2] == 0x6F && (au[b + 3] & 0xFE) == 0xBA
    }

    // MARK: - 解一個 access unit

    /// 解一個 access unit，成功回傳取樣數（結果在 `output`），還沒同步或資料壞掉回傳 nil
    public func decode(_ au: ArraySlice<UInt8>) -> Int? {
        // 讀位元時可能多讀幾個位元組：補 0
        var buf = [UInt8](au)
        let bufSize = buf.count
        buf.append(contentsOf: [UInt8](repeating: 0, count: 16))
        return buf.withUnsafeBufferPointer { decodeAccessUnit($0, size: bufSize) }
    }

    private func decodeAccessUnit(_ buf: UnsafeBufferPointer<UInt8>, size bufSize: Int) -> Int? {
        guard bufSize >= 4 else { return nil }
        let length = (Int(buf[0] & 0x0F) << 8 | Int(buf[1])) * 2
        guard length >= 4, length <= bufSize else { return nil }

        var gb = MLPBitReader(buf, byteOffset: 4, bitCount: (length - 4) * 8)
        var headerSize = 4
        var substrHeaderSize = 0
        var isMajorSyncUnit = false

        if gb.peek(31) == 0xF8726FBA >> 1 {
            guard readMajorSync(buf, at: 4, available: length - 4) else {
                paramsValid = false
                return nil
            }
            gb.skip(majorSyncHeaderSize * 8)
            isMajorSyncUnit = true
            headerSize += majorSyncHeaderSize
        }

        guard paramsValid else { return nil }

        var parityPresent = [Bool](repeating: false, count: Self.maxSubstreams)
        var dataLen = [Int](repeating: 0, count: Self.maxSubstreams)
        var substreamStart = 0

        for substr in 0..<numSubstreams {
            let extraword = gb.bit()
            let nonrestart = gb.bit()
            let checkdata = gb.bit()
            gb.skip(1)
            var end = gb.bits(12) * 2
            substrHeaderSize += 2
            if extraword {
                gb.skip(16)
                substrHeaderSize += 2
            }
            guard length >= headerSize + substrHeaderSize else { return fail() }
            guard nonrestart != isMajorSyncUnit else { return fail() }
            if end + headerSize + substrHeaderSize > length {
                end = length - headerSize - substrHeaderSize
            }
            guard end >= substreamStart else { return fail() }
            if substr > maxDecodedSubstream { continue }
            parityPresent[substr] = checkdata
            dataLen[substr] = end - substreamStart
            substreamStart = end
        }

        // 同位檢查：標頭的所有位元組 XOR 起來
        var parity: UInt8 = 0
        for i in 0..<4 { parity ^= buf[i] }
        for i in headerSize..<(headerSize + substrHeaderSize) { parity ^= buf[i] }
        guard ((parity >> 4) ^ parity) & 0xF == 0xF else { return fail() }

        var offset = headerSize + substrHeaderSize

        for substr in 0...maxDecodedSubstream {
            let s = substreams[substr]
            var gb = MLPBitReader(buf, byteOffset: offset, bitCount: dataLen[substr] * 8)
            matrixChanged = 0
            for i in filterChanged.indices { filterChanged[i] = 0 }
            s.blockpos = 0

            substream: do {
                repeat {
                    if gb.bit() {
                        if gb.bit() {
                            guard readRestartHeader(&gb, substr) else { break substream }
                            s.restartSeen = true
                        }
                        guard s.restartSeen else { break substream }
                        guard readDecodingParams(&gb, substr) else { break substream }
                    }
                    guard s.restartSeen else { break substream }

                    if ((outputChannels == 6 && (substreamInfo >> 2) & 0x3 != 0x3)
                        || (outputChannels == 8 && (substreamInfo >> 4) & 0x7 != 0x7
                            && (substreamInfo >> 4) & 0x7 != 0x6 && (substreamInfo >> 4) & 0x7 != 0x3))
                        && substr > 0 && substr < maxDecodedSubstream
                        && s.minChannel <= substreams[substr - 1].maxChannel {
                        break substream
                    }
                    if substr != maxDecodedSubstream,
                       s.codedChannels & substreams[maxDecodedSubstream].codedChannels != 0 {
                        break substream
                    }

                    guard readBlockData(&gb, substr) else { return nil }
                    guard gb.position < dataLen[substr] * 8 else { return nil }
                } while !gb.bit()

                gb.skip((-gb.position) & 15)

                if dataLen[substr] * 8 - gb.position >= 32 {
                    guard gb.bits(16) == 0xD234 else { return nil }
                    let shortenBy = gb.bits(16)
                    if shortenBy & 0x2000 != 0 {
                        s.blockpos -= min(shortenBy & 0x1FFF, s.blockpos)
                    }
                    s.endOfStream = true
                }
                if parityPresent[substr] {
                    guard dataLen[substr] * 8 - gb.position == 16 else { return nil }
                    gb.skip(16)
                }
                guard dataLen[substr] * 8 == gb.position else { return nil }
            }
            offset += dataLen[substr]
        }

        guard let frames = outputData(maxDecodedSubstream) else { return nil }

        for substr in 0...maxDecodedSubstream where substreams[substr].endOfStream {
            substreams[substr].endOfStream = false
            paramsValid = false
        }
        return frames
    }

    private func fail() -> Int? {
        paramsValid = false
        return nil
    }

    // MARK: - Major sync（mlp_parse.c）

    private static let thdChannelCount: [Int] = [2, 1, 1, 2, 2, 2, 2, 1, 1, 2, 2, 1, 1]
    private static let thdLayout: [UInt64] = [
        AVCh.fl | AVCh.fr, AVCh.fc, AVCh.lfe, AVCh.sl | AVCh.sr, AVCh.tfl | AVCh.tfr,
        AVCh.flc | AVCh.frc, AVCh.bl | AVCh.br, AVCh.bc, AVCh.tc, AVCh.sdl | AVCh.sdr,
        AVCh.wl | AVCh.wr, AVCh.tfc, AVCh.lfe2,
    ]
    /// TrueHD 位元流裡的聲道順序
    private static let thdChannelOrder: [Int] = [
        0, 1, 2, 3, 9, 10, 12, 14, 6, 7, 4, 5, 8, 11, 33, 34, 31, 32, 13, 35,
    ]

    private static func truehdChannels(_ map: Int) -> Int {
        (0..<13).reduce(0) { $0 + thdChannelCount[$1] * ((map >> $1) & 1) }
    }

    private static func truehdLayout(_ map: Int) -> UInt64 {
        (0..<13).reduce(UInt64(0)) { $0 | (((map >> $1) & 1) == 1 ? thdLayout[$1] : 0) }
    }

    private func readMajorSync(_ buf: UnsafeBufferPointer<UInt8>, at start: Int, available: Int) -> Bool {
        guard available >= 28 else { return false }
        var headerSize = 28
        if buf[start + 25] & 1 == 1 {
            headerSize += 2 + Int(buf[start + 26] >> 4) * 2
        }
        guard available >= headerSize else { return false }

        var gb = MLPBitReader(buf, byteOffset: start, bitCount: headerSize * 8)
        guard gb.bits(24) == 0xF8726F, gb.bits(8) == 0xBA else { return false }

        let ratebits = gb.bits(4)
        gb.skip(4)
        _ = gb.bits(2) // stream0 modifier
        _ = gb.bits(2) // stream1 modifier
        let arrangement1 = gb.bits(5)
        _ = gb.bits(2) // stream2 modifier
        let arrangement2 = gb.bits(13)
        gb.skip(48)
        _ = gb.bit() // vbr
        _ = gb.bits(15) // peak bitrate
        let numSubstreams = gb.bits(4)
        gb.skip(2)
        _ = gb.bits(2) // extended substream info
        let substreamInfo = gb.bits(8)

        guard ratebits != 0xF else { return false }
        let rate = (ratebits & 8 != 0 ? 44100 : 48000) << (ratebits & 7)
        let auSize = 40 << (ratebits & 7)
        let auPow2 = 64 << (ratebits & 7)
        guard rate <= 4 * 48000, auSize <= Self.maxBlocksize, auPow2 <= Self.maxBlocksizePow2 else { return false }
        guard numSubstreams > 0, numSubstreams <= Self.maxSubstreams else { return false }

        majorSyncHeaderSize = headerSize
        accessUnitSize = auSize
        accessUnitSizePow2 = auPow2
        sampleRate = rate
        self.numSubstreams = numSubstreams
        self.substreamInfo = substreamInfo
        isAtmos = numSubstreams == 4 && substreamInfo >> 7 == 1
        // 第 4 個子串流是全景聲的物件資料，不解
        maxDecodedSubstream = min(numSubstreams - 1, 2)

        let channels1 = Self.truehdChannels(arrangement1)
        let channels2 = Self.truehdChannels(arrangement2)
        let layout1 = Self.truehdLayout(arrangement1)
        let layout2 = Self.truehdLayout(arrangement2)
        // FFmpeg 的 parser 一開始就照標頭設好聲道數
        if outputChannels == 0 {
            outputChannels = channels2 == 0 ? channels1 : channels2
        }

        paramsValid = true
        for s in substreams { s.restartSeen = false }

        substreams[1].mask = layout1
        if channels1 == 2, channels2 == 2, outputChannels == 2 { substreams[0].mask = AVCh.stereo }
        if numSubstreams > 1 { substreams[0].mask = AVCh.stereo }
        if numSubstreams == 1, channels1 == 1, channels2 == 1, outputChannels == 1 { substreams[0].mask = AVCh.fc }
        if numSubstreams > 2 { substreams[2].mask = layout2 != 0 ? layout2 : layout1 }
        if outputChannels > 2 {
            if numSubstreams > 2 {
                substreams[1].mask = layout1
            } else {
                substreams[numSubstreams > 1 ? 1 : 0].mask = layout2
            }
        }
        // 標頭沒寫到的情況（FFmpeg 會失敗）：退回整體的聲道配置
        if substreams[maxDecodedSubstream].mask == 0 {
            substreams[maxDecodedSubstream].mask = layout2 != 0 ? layout2 : layout1
        }
        return true
    }

    // MARK: - Restart header

    private func readRestartHeader(_ gb: inout MLPBitReader, _ substr: Int) -> Bool {
        let s = substreams[substr]
        guard gb.bits(13) == 0x31EA >> 1 else { return false }
        let noiseType = gb.bit()
        gb.skip(16) // output timestamp
        let minChannel = gb.bits(4)
        let maxChannel = gb.bits(4)
        let maxMatrixChannel = gb.bits(4)

        guard maxMatrixChannel <= Self.maxMatrixChannelTrueHD else { return false }
        guard !(maxMatrixChannel > Self.maxMatrixChannelMLP && !noiseType) else { return false }
        guard maxChannel + 1 <= Self.maxChannels, maxChannel + 1 >= minChannel else { return false }

        s.minChannel = minChannel
        s.maxChannel = maxChannel
        s.codedChannels = ((UInt64(1) << UInt64(maxChannel - minChannel + 1)) - 1) << UInt64(minChannel)
        s.maxMatrixChannel = maxMatrixChannel
        s.noiseType = noiseType

        s.noiseShift = gb.bits(4)
        s.noisegenSeed = UInt32(gb.bits(23))
        gb.skip(19)
        s.dataCheckPresent = gb.bit()
        gb.skip(8) // lossless check
        gb.skip(16)

        for i in s.chAssign.indices { s.chAssign[i] = 0 }
        for ch in 0...s.maxMatrixChannel {
            let assign = gb.bits(6)
            // 位元流的第 n 個聲道 → 輸出順序（遮罩位元由低到高）的第幾個
            guard let channel = Self.thdChannel(mask: s.mask, index: assign) else { return false }
            let index = (s.mask & ((UInt64(1) << UInt64(channel)) - 1)).nonzeroBitCount
            guard index <= s.maxMatrixChannel else { return false }
            s.chAssign[index] = ch
        }
        gb.skip(8) // checksum

        s.paramPresenceFlags = 0xFF
        s.numPrimitiveMatrices = 0
        s.blocksize = 8
        for i in 0..<Self.maxChannels {
            s.outputShift[i] = 0
            s.quantStepSize[i] = 0
        }
        for ch in s.minChannel..<(s.maxChannel + 1) {
            s.channelParams[ch].firOrder = 0
            s.channelParams[ch].iirOrder = 0
            s.channelParams[ch].firShift = 0
            s.channelParams[ch].iirShift = 0
            // 預設是 24-bit 原始 PCM
            s.channelParams[ch].huffOffset = 0
            s.channelParams[ch].signHuffOffset = -(1 << 23)
            s.channelParams[ch].codebook = 0
            s.channelParams[ch].huffLsbs = 24
        }

        if substr == maxDecodedSubstream {
            outputMask = s.mask
            outputChannels = s.mask.nonzeroBitCount
        }
        return true
    }

    private static func thdChannel(mask: UInt64, index: Int) -> Int? {
        guard mask.nonzeroBitCount > index else { return nil }
        var remaining = index
        for channel in thdChannelOrder where mask & (UInt64(1) << UInt64(channel)) != 0 {
            if remaining == 0 { return channel }
            remaining -= 1
        }
        return nil
    }

    // MARK: - Decoding parameters

    private func readFilterParams(_ gb: inout MLPBitReader, _ substr: Int, _ channel: Int, iir: Bool) -> Bool {
        let s = substreams[substr]
        let slot = channel * 2 + (iir ? 1 : 0)
        guard filterChanged[slot] <= 1 else { return false }
        filterChanged[slot] += 1

        let order = gb.bits(4)
        guard order <= (iir ? Self.maxIIROrder : Self.maxFIROrder) else { return false }
        var cp = s.channelParams[channel]
        // 跟 FFmpeg 一樣：讀到一半出錯時，已經讀到的欄位也留著
        defer { s.channelParams[channel] = cp }
        if iir { cp.iirOrder = order } else { cp.firOrder = order }

        if order > 0 {
            let shift = gb.bits(4)
            if iir { cp.iirShift = shift } else { cp.firShift = shift }
            let coeffBits = gb.bits(5)
            let coeffShift = gb.bits(3)
            guard (1...16).contains(coeffBits), coeffBits + coeffShift <= 16 else { return false }
            for i in 0..<order {
                let c = Int32(gb.signedBits(coeffBits)) &* (1 << Int32(coeffShift))
                if iir { cp.iirCoeff[i] = c } else { cp.firCoeff[i] = c }
            }
            if gb.bit() {
                guard iir else { return false }
                let stateBits = gb.bits(4)
                let stateShift = gb.bits(4)
                for i in 0..<order {
                    cp.iirState[i] = stateBits > 0 ? Int32(gb.signedBits(stateBits)) &* (1 << Int32(stateShift)) : 0
                }
            }
        }
        return true
    }

    private func readMatrixParams(_ gb: inout MLPBitReader, _ substr: Int) -> Bool {
        let s = substreams[substr]
        guard matrixChanged <= 1 else { return false }
        matrixChanged += 1

        s.numPrimitiveMatrices = gb.bits(4)
        guard s.numPrimitiveMatrices <= Self.maxMatrices else {
            s.numPrimitiveMatrices = 0
            return false
        }
        for mat in 0..<s.numPrimitiveMatrices {
            s.matrixOutCh[mat] = gb.bits(4)
            let fracBits = gb.bits(4)
            s.lsbBypass[mat] = gb.bit()
            guard s.matrixOutCh[mat] <= s.maxMatrixChannel, fracBits <= 14 else {
                s.numPrimitiveMatrices = 0
                for i in s.matrixOutCh.indices { s.matrixOutCh[i] = 0 }
                return false
            }
            let maxChan = s.maxMatrixChannel + (s.noiseType ? 0 : 2)
            for ch in 0...maxChan {
                var value: Int32 = 0
                if gb.bit() { value = Int32(gb.signedBits(fracBits + 2)) }
                s.matrixCoeff[mat * Self.maxChannels + ch] = value &* (1 << Int32(14 - fracBits))
            }
            s.matrixNoiseShift[mat] = s.noiseType ? gb.bits(4) : 0
        }
        return true
    }

    private func readChannelParams(_ gb: inout MLPBitReader, _ substr: Int, _ ch: Int) -> Bool {
        let s = substreams[substr]
        if s.paramPresenceFlags & Self.paramFIR != 0, gb.bit() {
            guard readFilterParams(&gb, substr, ch, iir: false) else { return false }
        }
        if s.paramPresenceFlags & Self.paramIIR != 0, gb.bit() {
            guard readFilterParams(&gb, substr, ch, iir: true) else { return false }
        }
        var cp = s.channelParams[ch]
        guard cp.firOrder + cp.iirOrder <= 8 else { return false }
        guard !(cp.firOrder > 0 && cp.iirOrder > 0 && cp.firShift != cp.iirShift) else { return false }
        // 只有 IIR 時，濾波用 FIR 的精度
        if cp.firOrder == 0, cp.iirOrder > 0 { cp.firShift = cp.iirShift }

        if s.paramPresenceFlags & Self.paramHuffOffset != 0, gb.bit() {
            cp.huffOffset = Int32(gb.signedBits(15))
        }
        cp.codebook = gb.bits(2)
        cp.huffLsbs = gb.bits(5)
        if cp.codebook > 0, cp.huffLsbs > 24 {
            cp.huffLsbs = 0
            s.channelParams[ch] = cp
            return false
        }
        s.channelParams[ch] = cp
        return true
    }

    private func readDecodingParams(_ gb: inout MLPBitReader, _ substr: Int) -> Bool {
        let s = substreams[substr]
        var ok = true
        var recompute: UInt32 = 0

        if s.paramPresenceFlags & Self.paramPresence != 0, gb.bit() {
            s.paramPresenceFlags = UInt8(gb.bits(8))
        }
        if s.paramPresenceFlags & Self.paramBlocksize != 0, gb.bit() {
            s.blocksize = gb.bits(9)
            guard s.blocksize >= 8, s.blocksize <= accessUnitSize else {
                s.blocksize = 0
                return false
            }
        }
        if s.paramPresenceFlags & Self.paramMatrix != 0, gb.bit() {
            guard readMatrixParams(&gb, substr) else { return false }
        }
        if s.paramPresenceFlags & Self.paramOutshift != 0, gb.bit() {
            for ch in 0...s.maxMatrixChannel {
                s.outputShift[ch] = max(0, gb.signedBits(4))
            }
        }
        if s.paramPresenceFlags & Self.paramQuantstep != 0, gb.bit() {
            for ch in 0...s.maxChannel {
                s.quantStepSize[ch] = gb.bits(4)
                recompute |= 1 << UInt32(ch)
            }
        }
        for ch in s.minChannel..<(s.maxChannel + 1) where gb.bit() {
            recompute |= 1 << UInt32(ch)
            if !readChannelParams(&gb, substr, ch) {
                ok = false
                break
            }
        }

        for ch in 0...s.maxChannel where recompute & (1 << UInt32(ch)) != 0 {
            var cp = s.channelParams[ch]
            if cp.codebook > 0, cp.huffLsbs < s.quantStepSize[ch] {
                ok = false
                s.quantStepSize[ch] = 0
            }
            cp.signHuffOffset = Self.signHuffOffset(cp, quantStepSize: s.quantStepSize[ch])
            s.channelParams[ch] = cp
        }
        return ok
    }

    private static func signHuffOffset(_ cp: ChannelParams, quantStepSize: Int) -> Int32 {
        let lsbBits = cp.huffLsbs - quantStepSize
        let signShift = lsbBits + (cp.codebook > 0 ? 2 - cp.codebook : -1)
        var offset = cp.huffOffset
        if cp.codebook > 0 { offset &-= 7 &<< Int32(lsbBits) }
        if signShift >= 0 { offset &-= 1 &<< Int32(signShift) }
        return offset
    }

    // MARK: - 區塊資料

    private func readBlockData(_ gb: inout MLPBitReader, _ substr: Int) -> Bool {
        let s = substreams[substr]
        var expectedEnd = 0
        if s.dataCheckPresent {
            expectedEnd = gb.position
            expectedEnd += gb.bits(16)
        }
        guard s.blockpos + s.blocksize <= accessUnitSize else { return false }

        let mc = Self.maxChannels
        for i in (s.blockpos * mc)..<((s.blockpos + s.blocksize) * mc) { bypassedLsbs[i] = 0 }

        for i in 0..<s.blocksize {
            guard readHuffChannels(&gb, s, pos: i) else { return false }
        }
        for ch in s.minChannel..<(s.maxChannel + 1) {
            filterChannel(s, ch)
        }
        s.blockpos += s.blocksize

        if s.dataCheckPresent {
            _ = expectedEnd
            gb.skip(8)
        }
        return true
    }

    @inline(__always)
    private func readHuffChannels(_ gb: inout MLPBitReader, _ s: SubStream, pos: Int) -> Bool {
        let row = (pos + s.blockpos) * Self.maxChannels
        for mat in 0..<s.numPrimitiveMatrices where s.lsbBypass[mat] {
            bypassedLsbs[row + mat] = gb.bit() ? 1 : 0
        }
        for channel in s.minChannel..<(s.maxChannel + 1) {
            let cp = s.channelParams[channel]
            let quant = s.quantStepSize[channel]
            let lsbBits = cp.huffLsbs - quant
            var result: Int32 = 0
            if cp.codebook > 0 {
                guard let symbol = gb.vlc(MLPHuffman.tables[cp.codebook - 1]) else { return false }
                result = Int32(symbol)
            }
            if lsbBits > 0 {
                result = (result &<< Int32(lsbBits)) &+ Int32(truncatingIfNeeded: gb.bits(lsbBits))
            }
            result &+= cp.signHuffOffset
            result = result &* (1 &<< Int32(quant))
            sampleBuffer[row + channel] = result
        }
        return true
    }

    /// 預測濾波器（FIR＋IIR），同時更新濾波器狀態
    private func filterChannel(_ s: SubStream, _ channel: Int) {
        var cp = s.channelParams[channel]
        let base = Self.maxBlocksize
        let mask = Int32(truncatingIfNeeded: -(1 << s.quantStepSize[channel]))
        let shift = Int64(cp.firShift)
        let firOrder = cp.firOrder, iirOrder = cp.iirOrder
        let blocksize = s.blocksize
        let mc = Self.maxChannels

        for i in 0..<Self.maxFIROrder { firScratch[base + i] = cp.firState[i] }
        for i in 0..<Self.maxIIROrder { iirScratch[base + i] = cp.iirState[i] }

        firScratch.withUnsafeMutableBufferPointer { fir in
            iirScratch.withUnsafeMutableBufferPointer { iir in
                sampleBuffer.withUnsafeMutableBufferPointer { samples in
                    cp.firCoeff.withUnsafeBufferPointer { fc in
                        cp.iirCoeff.withUnsafeBufferPointer { ic in
                            var p = base
                            var index = s.blockpos * mc + channel
                            for _ in 0..<blocksize {
                                let residual = samples[index]
                                var accum: Int64 = 0
                                for o in 0..<firOrder { accum &+= Int64(fir[p + o]) &* Int64(fc[o]) }
                                for o in 0..<iirOrder { accum &+= Int64(iir[p + o]) &* Int64(ic[o]) }
                                accum >>= shift
                                let result = Int32(truncatingIfNeeded: accum &+ Int64(residual)) & mask
                                p -= 1
                                fir[p] = result
                                iir[p] = Int32(truncatingIfNeeded: Int64(result) &- accum)
                                samples[index] = result
                                index += mc
                            }
                        }
                    }
                }
            }
        }

        let p = base - blocksize
        for i in 0..<Self.maxFIROrder { cp.firState[i] = firScratch[p + i] }
        for i in 0..<Self.maxIIROrder { cp.iirState[i] = iirScratch[p + i] }
        s.channelParams[channel] = cp
    }

    // MARK: - 雜訊與矩陣

    private func generate2NoiseChannels(_ s: SubStream) {
        var seed = s.noisegenSeed
        let maxchan = s.maxMatrixChannel
        let mul = Int32(1) << Int32(s.noiseShift)
        for i in 0..<s.blockpos {
            let shr7 = UInt16(truncatingIfNeeded: seed >> 7)
            let row = i * Self.maxChannels
            sampleBuffer[row + maxchan + 1] = Int32(Int8(truncatingIfNeeded: seed >> 15)) &* mul
            sampleBuffer[row + maxchan + 2] = Int32(Int8(truncatingIfNeeded: shr7)) &* mul
            seed = (seed << 16) ^ UInt32(shr7) ^ (UInt32(shr7) << 5)
        }
        s.noisegenSeed = seed
    }

    private func fillNoiseBuffer(_ s: SubStream) {
        var seed = s.noisegenSeed
        for i in 0..<accessUnitSizePow2 {
            let shr15 = UInt8(truncatingIfNeeded: seed >> 15)
            noiseBuffer[i] = MLPHuffman.noiseTable[Int(shr15)]
            seed = (seed << 8) ^ UInt32(shr15) ^ (UInt32(shr15) << 5)
        }
        s.noisegenSeed = seed
    }

    private func outputData(_ substr: Int) -> Int? {
        let s = substreams[substr]
        guard outputChannels == s.maxMatrixChannel + 1, s.blockpos > 0 else { return nil }

        var maxchan = s.maxMatrixChannel
        if !s.noiseType {
            generate2NoiseChannels(s)
            maxchan += 2
        } else {
            fillNoiseBuffer(s)
        }

        let mc = Self.maxChannels
        let blockpos = s.blockpos
        let pow2Mask = accessUnitSizePow2 - 1
        for mat in 0..<s.numPrimitiveMatrices {
            let dest = s.matrixOutCh[mat]
            let noiseShift = s.matrixNoiseShift[mat]
            let mask = Int64(Int32(truncatingIfNeeded: -(1 << s.quantStepSize[dest])))
            var index = s.numPrimitiveMatrices - mat
            let index2 = 2 * index + 1
            let coeffBase = mat * mc
            sampleBuffer.withUnsafeMutableBufferPointer { samples in
                s.matrixCoeff.withUnsafeBufferPointer { coeffs in
                    for i in 0..<blockpos {
                        let row = i * mc
                        var accum: Int64 = 0
                        for src in 0...maxchan {
                            accum &+= Int64(samples[row + src]) &* Int64(coeffs[coeffBase + src])
                        }
                        if noiseShift != 0 {
                            index &= pow2Mask
                            accum &+= Int64(noiseBuffer[index]) &* Int64(1 << (noiseShift + 7))
                            index += index2
                        }
                        let value = ((accum >> 14) & mask) &+ Int64(bypassedLsbs[row + mat])
                        samples[row + dest] = Int32(truncatingIfNeeded: value)
                    }
                }
            }
        }

        let channels = s.maxMatrixChannel + 1
        if output.count != blockpos * channels {
            output = [Int32](repeating: 0, count: blockpos * channels)
        }
        var n = 0
        for i in 0..<blockpos {
            let row = i * mc
            for outCh in 0..<channels {
                let matCh = s.chAssign[outCh]
                output[n] = sampleBuffer[row + matCh] &<< Int32(s.outputShift[matCh])
                n += 1
            }
        }
        format = TrueHDFormat(sampleRate: sampleRate, channelMask: outputMask,
                              accessUnitSize: accessUnitSize, isAtmos: isAtmos)
        return blockpos
    }
}

// MARK: - 聲道位元（FFmpeg 的 AV_CH_*）

public enum AVCh {
    public static let fl: UInt64 = 1 << 0
    public static let fr: UInt64 = 1 << 1
    public static let fc: UInt64 = 1 << 2
    public static let lfe: UInt64 = 1 << 3
    public static let bl: UInt64 = 1 << 4
    public static let br: UInt64 = 1 << 5
    public static let flc: UInt64 = 1 << 6
    public static let frc: UInt64 = 1 << 7
    public static let bc: UInt64 = 1 << 8
    public static let sl: UInt64 = 1 << 9
    public static let sr: UInt64 = 1 << 10
    public static let tc: UInt64 = 1 << 11
    public static let tfl: UInt64 = 1 << 12
    public static let tfc: UInt64 = 1 << 13
    public static let tfr: UInt64 = 1 << 14
    public static let wl: UInt64 = 1 << 31
    public static let wr: UInt64 = 1 << 32
    public static let sdl: UInt64 = 1 << 33
    public static let sdr: UInt64 = 1 << 34
    public static let lfe2: UInt64 = 1 << 35
    public static let stereo: UInt64 = fl | fr
}

// MARK: - 讀位元

struct MLPBitReader {
    private let buf: UnsafeBufferPointer<UInt8>
    private let start: Int
    private let count: Int
    /// 從 start 起算讀了幾個位元
    private(set) var position = 0

    /// buf 後面要補至少 8 個 0（多讀不會越界）
    init(_ buf: UnsafeBufferPointer<UInt8>, byteOffset: Int, bitCount: Int) {
        self.buf = buf
        start = byteOffset * 8
        count = bitCount
    }

    /// 偷看 n 個位元（n ≤ 32）
    @inline(__always)
    func peek(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        let bit = start + position
        let byte = bit >> 3
        guard byte + 8 <= buf.count else { return slowPeek(n) }
        var word: UInt64 = 0
        for i in 0..<8 { word = (word << 8) | UInt64(buf[byte + i]) }
        word <<= UInt64(bit & 7)
        return Int(word >> UInt64(64 - n))
    }

    private func slowPeek(_ n: Int) -> Int {
        var value = 0
        var bit = start + position
        for _ in 0..<n {
            let byte = bit >> 3
            let b = byte < buf.count ? Int((buf[byte] >> UInt8(7 - (bit & 7))) & 1) : 0
            value = (value << 1) | b
            bit += 1
        }
        return value
    }

    @inline(__always)
    mutating func bits(_ n: Int) -> Int {
        let v = peek(n)
        position += n
        return v
    }

    @inline(__always)
    mutating func signedBits(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        let v = bits(n)
        return v & (1 << (n - 1)) != 0 ? v - (1 << n) : v
    }

    @inline(__always)
    mutating func bit() -> Bool { bits(1) == 1 }

    mutating func skip(_ n: Int) { position += n }

    /// 霍夫曼碼（最長 9 位元）
    @inline(__always)
    mutating func vlc(_ table: [UInt16]) -> Int? {
        let entry = table[peek(9)]
        let length = Int(entry & 0xF)
        guard length > 0 else { return nil }
        position += length
        return Int(entry >> 4)
    }
}

enum MLPHuffman {
    /// (碼, 長度)，索引就是符號
    private static let raw: [[(UInt16, Int)]] = [
        [(0x01, 9), (0x01, 8), (0x01, 7), (0x01, 6), (0x01, 5), (0x01, 4), (0x01, 3),
         (0x04, 3), (0x05, 3), (0x06, 3), (0x07, 3),
         (0x03, 3), (0x05, 4), (0x09, 5), (0x11, 6), (0x21, 7), (0x41, 8), (0x81, 9)],
        [(0x01, 9), (0x01, 8), (0x01, 7), (0x01, 6), (0x01, 5), (0x01, 4), (0x01, 3),
         (0x02, 2), (0x03, 2),
         (0x03, 3), (0x05, 4), (0x09, 5), (0x11, 6), (0x21, 7), (0x41, 8), (0x81, 9)],
        [(0x01, 9), (0x01, 8), (0x01, 7), (0x01, 6), (0x01, 5), (0x01, 4), (0x01, 3),
         (0x01, 1),
         (0x03, 3), (0x05, 4), (0x09, 5), (0x11, 6), (0x21, 7), (0x41, 8), (0x81, 9)],
    ]

    /// 9 位元查表：高 12 位元是符號、低 4 位元是碼長（0 表示不合法）
    static let tables: [[UInt16]] = raw.map { codes in
        var table = [UInt16](repeating: 0, count: 512)
        for (symbol, (code, length)) in codes.enumerated() {
            let first = Int(code) << (9 - length)
            for i in first..<(first + (1 << (9 - length))) {
                table[i] = UInt16(symbol << 4 | length)
            }
        }
        return table
    }

    static let noiseTable: [Int8] = [
        30, 51, 22, 54, 3, 7, -4, 38, 14, 55, 46, 81, 22, 58, -3, 2,
        52, 31, -7, 51, 15, 44, 74, 30, 85, -17, 10, 33, 18, 80, 28, 62,
        10, 32, 23, 69, 72, 26, 35, 17, 73, 60, 8, 56, 2, 6, -2, -5,
        51, 4, 11, 50, 66, 76, 21, 44, 33, 47, 1, 26, 64, 48, 57, 40,
        38, 16, -10, -28, 92, 22, -18, 29, -10, 5, -13, 49, 19, 24, 70, 34,
        61, 48, 30, 14, -6, 25, 58, 33, 42, 60, 67, 17, 54, 17, 22, 30,
        67, 44, -9, 50, -11, 43, 40, 32, 59, 82, 13, 49, -14, 55, 60, 36,
        48, 49, 31, 47, 15, 12, 4, 65, 1, 23, 29, 39, 45, -2, 84, 69,
        0, 72, 37, 57, 27, 41, -15, -16, 35, 31, 14, 61, 24, 0, 27, 24,
        16, 41, 55, 34, 53, 9, 56, 12, 25, 29, 53, 5, 20, -20, -8, 20,
        13, 28, -3, 78, 38, 16, 11, 62, 46, 29, 21, 24, 46, 65, 43, -23,
        89, 18, 74, 21, 38, -12, 19, 12, -19, 8, 15, 33, 4, 57, 9, -8,
        36, 35, 26, 28, 7, 83, 63, 79, 75, 11, 3, 87, 37, 47, 34, 40,
        39, 19, 20, 42, 27, 34, 39, 77, 13, 42, 59, 64, 45, -1, 32, 37,
        45, -5, 53, -6, 7, 36, 50, 23, 6, 32, 9, -21, 18, 71, 27, 52,
        -25, 31, 35, 42, -1, 68, 63, 52, 26, 43, 66, 37, 41, 25, 40, 70,
    ]
}
