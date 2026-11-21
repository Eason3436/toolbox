import Core
import Foundation

enum ProxyError: Error {
    case http(Int)
    case unsatisfiable(total: Int64?)
    case badResponse
}

/// Drive 檔案的分段快取：一段 4 MB，同時下載好幾段、往前多讀幾段。
///
/// 為什麼不直接轉送 AVPlayer 的 Range：Drive 單一連線的速度常常只有每秒幾 MB，
/// 1080p 藍光片的位元率一高就追不上，播十幾秒就停下來緩衝。分段平行下載可以把速度疊起來。
///
/// 另外會在讀到 moov 時記下要改名的 sample entry（hev1 → hvc1），送出資料時改掉，
/// iPhone 才會解 ffmpeg 預設標成 hev1 的 HEVC（不然只有聲音、畫面一個 Q）。
actor ChunkCache {
    static let chunkSize: Int64 = 4 * 1024 * 1024
    /// 記憶體裡最多放多少
    static let maxBytes = 192 * 1024 * 1024
    /// 送出目前這段時，往後先下載幾段
    static let readAhead: Int64 = 6
    /// 同時最多幾個下載
    static let maxConcurrent = 6

    struct Key: Hashable, Sendable {
        let fileId: String
        let index: Int64
    }

    struct FileInfo: Sendable {
        var total: Int64?
        var contentType: String?
        /// 絕對位置 → 要換成的位元組（hev1 → hvc1）
        var patches: [Int64: UInt8] = [:]
    }

    private struct Downloaded: Sendable {
        let data: Data
        let total: Int64?
        let contentType: String?
    }

    private let session: URLSession
    private let tokenProvider: LocalStreamProxy.TokenProvider
    private let upstreamURL: @Sendable (String) -> URL

    private var chunks: [Key: Data] = [:]
    private var lru: [Key] = []
    private var bytes = 0
    private var inflight: [Key: Task<Downloaded, Error>] = [:]
    private var files: [String: FileInfo] = [:]
    private var preparing: [String: Task<Void, Never>] = [:]

    init(tokenProvider: @escaping LocalStreamProxy.TokenProvider, upstreamURL: @escaping @Sendable (String) -> URL) {
        self.tokenProvider = tokenProvider
        self.upstreamURL = upstreamURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = Self.maxConcurrent + 2
        session = URLSession(configuration: config)
    }

    // MARK: - 對外

    func info(_ fileId: String) -> FileInfo? { files[fileId] }

    /// 第一次讀這個檔案：拿總長度、找 moov 裡要改名的 sample entry。同一個檔案只做一次
    func prepare(_ fileId: String) async {
        if let task = preparing[fileId] {
            await task.value
            // 上次網路不好沒讀到：再試一次
            if files[fileId]?.total != nil { return }
        }
        let task = Task { await self.scan(fileId) }
        preparing[fileId] = task
        await task.value
    }

    /// 拿某一段（有快取就直接給，正在下載就等它）
    func chunk(_ fileId: String, _ index: Int64) async throws -> Data {
        let key = Key(fileId: fileId, index: index)
        if let data = chunks[key] {
            touch(key)
            return data
        }
        let task = inflight[key] ?? start(key)
        let result = try await task.value
        record(fileId, result)
        return result.data
    }

    /// 往後先下載幾段（已經有的、正在下載的跳過；同時下載太多就先不排）
    func prefetch(_ fileId: String, after index: Int64, last: Int64) {
        var i = index + 1
        while i <= min(index + Self.readAhead, last) {
            let key = Key(fileId: fileId, index: i)
            if chunks[key] == nil, inflight[key] == nil {
                guard inflight.count < Self.maxConcurrent else { return }
                _ = start(key)
            }
            i += 1
        }
    }

    /// 記憶體不夠時全部丟掉
    func purge() {
        chunks.removeAll()
        lru.removeAll()
        bytes = 0
    }

    // MARK: - 下載

    private func start(_ key: Key) -> Task<Downloaded, Error> {
        let session = session, tokenProvider = tokenProvider, url = upstreamURL(key.fileId)
        let task = Task {
            try await Self.download(key, url: url, session: session, tokenProvider: tokenProvider)
        }
        inflight[key] = task
        Task { await self.finish(key, task) }
        return task
    }

    private func finish(_ key: Key, _ task: Task<Downloaded, Error>) async {
        let result = await task.result
        if inflight[key] == task { inflight[key] = nil }
        if case .success(let downloaded) = result {
            record(key.fileId, downloaded)
            store(key, downloaded.data)
        }
    }

    private func record(_ fileId: String, _ d: Downloaded) {
        var info = files[fileId] ?? FileInfo()
        if let total = d.total { info.total = total }
        if let type = d.contentType, info.contentType == nil { info.contentType = type }
        files[fileId] = info
    }

    private func store(_ key: Key, _ data: Data) {
        guard chunks[key] == nil else { return }
        chunks[key] = data
        lru.append(key)
        bytes += data.count
        while bytes > Self.maxBytes, let oldest = lru.first {
            lru.removeFirst()
            if let removed = chunks.removeValue(forKey: oldest) { bytes -= removed.count }
        }
    }

    private func touch(_ key: Key) {
        if let i = lru.firstIndex(of: key) {
            lru.remove(at: i)
            lru.append(key)
        }
    }

    nonisolated private static func download(
        _ key: Key, url: URL, session: URLSession, tokenProvider: LocalStreamProxy.TokenProvider
    ) async throws -> Downloaded {
        let start = key.index * chunkSize
        let end = start + chunkSize - 1
        var forceRefresh = false
        var attempt = 0
        while true {
            attempt += 1
            let token = try await tokenProvider(forceRefresh)
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where attempt < 3 && [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                try await Task.sleep(for: .milliseconds(400 * attempt))
                continue
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            let contentRange = http?.value(forHTTPHeaderField: "Content-Range")
            switch status {
            case 401 where !forceRefresh:
                // token 剛好過期：換新的再試一次
                forceRefresh = true
                continue
            case 429 where attempt < 3, 500..<600 where attempt < 3:
                try await Task.sleep(for: .milliseconds(600 * attempt))
                continue
            case 416:
                throw ProxyError.unsatisfiable(total: contentRange.flatMap(totalLength))
            case 206:
                return Downloaded(data: data, total: contentRange.flatMap(totalLength), contentType: http?.value(forHTTPHeaderField: "Content-Type"))
            case 200:
                // 伺服器沒理 Range，整個檔案回來了：切出這一段
                let total = Int64(data.count)
                let lo = Int(min(start, total)), hi = Int(min(end + 1, total))
                return Downloaded(data: data.subdata(in: lo..<hi), total: total, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
            default:
                throw ProxyError.http(status)
            }
        }
    }

    /// 「bytes 0-4194303/123456789」→ 123456789
    nonisolated private static func totalLength(_ contentRange: String) -> Int64? {
        guard let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    // MARK: - 找 moov

    private func scan(_ fileId: String) async {
        do {
            _ = try await chunk(fileId, 0)
            guard let total = files[fileId]?.total else { return }
            var offset: Int64 = 0
            for _ in 0..<64 {
                guard offset + 8 <= total else { return }
                let head = try await read(fileId, offset: offset, length: min(16, total - offset))
                guard let box = MP4Boxes.header(head) else { return }
                let size = box.size == 0 ? total - offset : box.size
                if box.type == "moov" {
                    guard size <= 96 * 1024 * 1024 else { return }
                    let moov = try await read(fileId, offset: offset, length: size)
                    var map: [Int64: UInt8] = [:]
                    for patch in MP4Boxes.sampleEntryPatches(inMoov: moov) {
                        for (j, byte) in patch.replacement.enumerated() {
                            map[offset + Int64(patch.offset + j)] = byte
                        }
                    }
                    files[fileId, default: FileInfo()].patches = map
                    return
                }
                offset += size
            }
        } catch {
            // 讀不到就不改，照原樣播
        }
    }

    /// 讀一段位元組（可能跨好幾段；先全部開始下載再依序拿）
    private func read(_ fileId: String, offset: Int64, length: Int64) async throws -> [UInt8] {
        guard length > 0 else { return [] }
        let first = offset / Self.chunkSize
        let last = (offset + length - 1) / Self.chunkSize
        for i in first...last {
            let key = Key(fileId: fileId, index: i)
            if chunks[key] == nil, inflight[key] == nil { _ = start(key) }
        }
        var out: [UInt8] = []
        out.reserveCapacity(Int(length))
        for i in first...last {
            let data = try await chunk(fileId, i)
            let chunkStart = i * Self.chunkSize
            let lo = max(offset, chunkStart) - chunkStart
            let hi = min(offset + length, chunkStart + Int64(data.count)) - chunkStart
            if lo < hi {
                out.append(contentsOf: data[(data.startIndex + Int(lo))..<(data.startIndex + Int(hi))])
            }
            if Int64(data.count) < Self.chunkSize { break }
        }
        return out
    }
}
