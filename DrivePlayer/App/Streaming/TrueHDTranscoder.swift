import Core
import Foundation

/// 播放器讀 PCM 區時，找出對應的 TrueHD sample、從 `ChunkCache` 拿資料、解成 PCM。
///
/// 一個檔案一個。解碼器有狀態（接著上次解或往前退一段重新開始），所以同一時間只處理一個請求：
/// actor 在等下載時會讓別的請求進來，這裡另外排隊。
actor TrueHDTranscoder {
    private let fileId: String
    private let cache: ChunkCache
    private let renderer: TrueHDPCMRenderer
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(fileId: String, plan: TrueHDRemuxPlan, cache: ChunkCache) {
        self.fileId = fileId
        self.cache = cache
        renderer = TrueHDPCMRenderer(plan: plan)
    }

    /// PCM 區裡的一段（相對 PCM 區開頭）
    func pcm(_ range: Range<Int64>) async throws -> Data {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        let needed = renderer.samplesNeeded(for: range)
        let samples = try await fetch(needed)
        return Data(renderer.render(range, samples: samples, startingAt: needed.lowerBound))
    }

    /// 讀 TrueHD sample：位置相連的合併成一次讀
    private func fetch(_ range: Range<Int>) async throws -> [[UInt8]] {
        let locations = renderer.plan.table.locations(range)
        var out: [[UInt8]] = []
        out.reserveCapacity(locations.count)
        var i = 0
        while i < locations.count {
            var j = i
            var end = locations[i].offset + Int64(locations[i].size)
            while j + 1 < locations.count, locations[j + 1].offset == end, end - locations[i].offset < 4 * 1024 * 1024 {
                j += 1
                end += Int64(locations[j].size)
            }
            let start = locations[i].offset
            let bytes = try await cache.read(fileId, offset: start, length: end - start)
            for k in i...j {
                let lo = Int(locations[k].offset - start)
                let hi = min(bytes.count, lo + locations[k].size)
                out.append(lo < hi ? Array(bytes[lo..<hi]) : [])
            }
            i = j + 1
        }
        return out
    }

    private func lock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// 每個檔案一個轉換器；只留最近用的幾個（每個記著最近解好的幾秒 PCM）
actor TranscoderRegistry {
    private var transcoders: [String: TrueHDTranscoder] = [:]
    private var order: [String] = []

    func transcoder(fileId: String, plan: TrueHDRemuxPlan, cache: ChunkCache) -> TrueHDTranscoder {
        if let existing = transcoders[fileId] {
            order.removeAll { $0 == fileId }
            order.append(fileId)
            return existing
        }
        let made = TrueHDTranscoder(fileId: fileId, plan: plan, cache: cache)
        transcoders[fileId] = made
        order.append(fileId)
        while order.count > 2 {
            transcoders[order.removeFirst()] = nil
        }
        return made
    }
}
