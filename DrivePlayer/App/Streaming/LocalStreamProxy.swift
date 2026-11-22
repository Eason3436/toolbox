import Core
import Foundation
import Network

/// 本機串流代理：AVPlayer（之後的 mpv 也一樣）播放 `http://127.0.0.1:{port}/stream/{fileId}`，
/// 這裡用當下有效的 token 向 Drive 分段下載（`ChunkCache`），再照播放器要的 Range 回給它。
///
/// 為什麼要代理：Google 的 access token 一小時就過期，直接把 Authorization 塞進 AVURLAsset，
/// 長片播到後半段會收到 401 而中斷。順便：平行分段下載（比單一連線快很多）、修正 hev1 標記、
/// 把 iPhone 解不了的 TrueHD 音軌換成邊播邊解的 PCM（`TrueHDRemux`）。
///
/// - 只聽 loopback，外部連不進來
/// - 送給播放器時等 socket 吃掉才送下一段；往前最多多下載 `ChunkCache.readAhead` 段（不會整部讀進記憶體）
/// - 一個連線只處理一個請求（`Connection: close`），AVPlayer 會自己開新的連線
/// - 回到前景時呼叫 `ensureRunning()`，被系統關掉的 listener 會在同一個 port 重開
final class LocalStreamProxy: @unchecked Sendable {
    typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    let cache: ChunkCache
    let transcoders = TranscoderRegistry()

    /// 所有狀態都只在這個 queue 上讀寫
    let queue = DispatchQueue(label: "DrivePlayer.LocalStreamProxy", qos: .userInitiated)

    private var listener: NWListener?
    private var listenerPort: NWEndpoint.Port?
    private var waiting: [CheckedContinuation<UInt16, Error>] = []
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]

    init(tokenProvider: @escaping TokenProvider, upstreamURL: @escaping @Sendable (String) -> URL = { DriveAPI.mediaURL(fileId: $0) }) {
        cache = ChunkCache(tokenProvider: tokenProvider, upstreamURL: upstreamURL)
    }

    /// 記憶體不夠：丟掉快取的分段
    func purgeCache() {
        let cache = cache
        Task { await cache.purge() }
    }

    // MARK: - 對外

    /// 播放用的網址（代理沒在跑會先啟動）。TrueHD 轉換過的檔案是 QuickTime 格式，副檔名換成 .mov
    func streamURL(fileId: String, filename: String? = nil) async throws -> URL {
        let port = try await ensureRunning()
        var name = filename
        await cache.prepare(fileId)
        if let filename, await cache.info(fileId)?.remux != nil {
            name = (filename as NSString).deletingPathExtension + ".mov"
        }
        return URL(string: "http://127.0.0.1:\(port)" + StreamRoute.path(fileId: fileId, filename: name))!
    }

    /// 轉換後的 TrueHD 格式（沒轉換是 nil）
    func remuxedAudio(fileId: String) async -> TrueHDFormat? {
        await cache.info(fileId)?.remux?.format
    }

    /// 確保 listener 在跑，回傳 port
    @discardableResult
    func ensureRunning() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            queue.async { self.start(cont) }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for c in self.connections.values { c.close() }
        }
    }

    // MARK: - listener（queue 上）

    private func start(_ cont: CheckedContinuation<UInt16, Error>) {
        if let listener, listener.state == .ready, let port = listener.port {
            cont.resume(returning: port.rawValue)
            return
        }
        waiting.append(cont)
        guard listener == nil else { return } // 正在啟動
        startListener(port: listenerPort)
    }

    private func startListener(port: NWEndpoint.Port?) {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            l = try NWListener(using: params, on: port ?? .any)
        } catch {
            if port != nil { startListener(port: nil); return }
            fail(error)
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            switch state {
            case .ready:
                self.listenerPort = l.port
                let port = l.port?.rawValue ?? 0
                let waiting = self.waiting
                self.waiting = []
                for c in waiting { c.resume(returning: port) }
            case .failed(let error):
                l.cancel()
                self.listener = nil
                // 原本的 port 被占走：換一個
                if port != nil, !self.waiting.isEmpty {
                    self.listenerPort = nil
                    self.startListener(port: nil)
                } else {
                    self.fail(error)
                }
            case .cancelled:
                if self.listener === l { self.listener = nil }
            default:
                break
            }
        }
        l.start(queue: queue)
    }

    private func fail(_ error: Error) {
        let waiting = self.waiting
        self.waiting = []
        for c in waiting { c.resume(throwing: error) }
    }

    private func accept(_ connection: NWConnection) {
        let handler = ProxyConnection(connection: connection, proxy: self)
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }

    fileprivate func remove(_ handler: ProxyConnection) {
        connections[ObjectIdentifier(handler)] = nil
    }
}

/// 一個 AVPlayer 的連線（一個請求）。連線狀態在 proxy.queue 上；回應在一個 Task 裡依序送出。
private final class ProxyConnection: @unchecked Sendable {
    private let connection: NWConnection
    private unowned let proxy: LocalStreamProxy
    private var buffer = Data()
    private var closed = false
    private var serving: Task<Void, Never>?

    init(connection: NWConnection, proxy: LocalStreamProxy) {
        self.connection = connection
        self.proxy = proxy
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: proxy.queue)
        receive()
    }

    // MARK: 讀請求

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            if let (head, _) = HTTPRequestHead.parse(self.buffer) {
                self.handle(head)
            } else if self.buffer.count > 64 * 1024 {
                self.respondError(400, "請求標頭太大")
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func handle(_ head: HTTPRequestHead) {
        guard head.method == "GET" || head.method == "HEAD" else {
            respondError(405, "只支援 GET／HEAD")
            return
        }
        guard let fileId = StreamRoute.fileId(from: head.target) else {
            respondError(404, "找不到")
            return
        }
        let cache = proxy.cache
        let transcoders = proxy.transcoders
        serving = Task { [self] in
            await serve(head, fileId: fileId, cache: cache, transcoders: transcoders)
            proxy.queue.async { self.close() }
        }
    }

    // MARK: 回應

    private func serve(_ head: HTTPRequestHead, fileId: String, cache: ChunkCache, transcoders: TranscoderRegistry) async {
        var headSent = false
        do {
            await cache.prepare(fileId)
            guard let info = await cache.info(fileId), let original = info.total, let total = info.servedSize, total > 0 else {
                throw ProxyError.badResponse
            }
            let contentType = info.remux != nil ? "video/quicktime" : (info.contentType ?? "video/mp4")

            if head.method == "HEAD" {
                let response = HTTPResponseHead(status: 200, headers: [
                    ("Content-Type", contentType), ("Content-Length", "\(total)"),
                    ("Accept-Ranges", "bytes"), ("Connection", "close"),
                ])
                _ = await write(response.serialized(), final: true)
                return
            }

            let requested = ByteRange.parse(head.range)
            var start: Int64 = 0
            var end = total - 1
            if let requested {
                if let s = requested.start {
                    start = s
                    if let e = requested.end { end = min(e, total - 1) }
                } else if let suffix = requested.end {
                    start = max(0, total - suffix)
                }
            }
            guard start < total, start <= end else { throw ProxyError.unsatisfiable(total: total) }

            let status = requested == nil ? 200 : 206
            var headers: [(String, String)] = [
                ("Content-Type", contentType), ("Content-Length", "\(end - start + 1)"), ("Accept-Ranges", "bytes"),
            ]
            if status == 206 { headers.append(("Content-Range", "bytes \(start)-\(end)/\(total)")) }
            headers.append(("Connection", "close"))
            guard await write(HTTPResponseHead(status: status, headers: headers).serialized()) else { return }
            headSent = true

            // 原檔的部分照分段快取送；TrueHD 轉換時，後面接新的 moov 和解出來的 PCM
            let originalEnd = min(end, original - 1)
            var pos = start
            if pos <= originalEnd {
                let size = ChunkCache.chunkSize
                let lastIndex = originalEnd / size
                while pos <= originalEnd {
                    try Task.checkCancellation()
                    let index = pos / size
                    await cache.prefetch(fileId, after: index, last: lastIndex)
                    let data = try await cache.chunk(fileId, index)
                    let chunkStart = index * size
                    let lo = Int(pos - chunkStart)
                    let hi = Int(min(originalEnd + 1, chunkStart + Int64(data.count)) - chunkStart)
                    guard lo < hi else { throw ProxyError.badResponse }
                    var slice = Data(data[(data.startIndex + lo)..<(data.startIndex + hi)])
                    if !info.patches.isEmpty {
                        let sliceEnd = pos + Int64(slice.count)
                        for (offset, byte) in info.patches where offset >= pos && offset < sliceEnd {
                            slice[Int(offset - pos)] = byte
                        }
                    }
                    guard await write(slice) else { return }
                    pos += Int64(hi - lo)
                }
            }
            if let plan = info.remux, pos <= end {
                if pos < plan.pcmStart {
                    let lo = Int(pos - plan.originalSize)
                    let hi = Int(min(end + 1, plan.pcmStart) - plan.originalSize)
                    guard await write(Data(plan.header[lo..<hi])) else { return }
                    pos += Int64(hi - lo)
                }
                if pos <= end {
                    let transcoder = await transcoders.transcoder(fileId: fileId, plan: plan, cache: cache)
                    // 一次送一個 PCM chunk（約 0.5 秒）
                    let piece = Int64(TrueHDRemux.framesPerChunk * plan.bytesPerFrame)
                    while pos <= end {
                        try Task.checkCancellation()
                        let relative = pos - plan.pcmStart
                        let pieceEnd = min(end + 1 - plan.pcmStart, (relative / piece + 1) * piece)
                        let data = try await transcoder.pcm(relative..<pieceEnd)
                        guard await write(data) else { return }
                        pos = plan.pcmStart + pieceEnd
                    }
                }
            }
            _ = await write(nil, final: true)
        } catch ProxyError.unsatisfiable(let total) {
            guard !headSent else { return }
            var headers: [(String, String)] = [("Content-Length", "0"), ("Connection", "close")]
            if let total { headers.insert(("Content-Range", "bytes */\(total)"), at: 0) }
            _ = await write(HTTPResponseHead(status: 416, headers: headers).serialized(), final: true)
        } catch {
            guard !headSent, !(error is CancellationError) else { return }
            let (status, message) = Self.describe(error)
            _ = await write(HTTPResponseHead.error(status, message: message), final: true)
        }
    }

    private static func describe(_ error: Error) -> (Int, String) {
        switch error {
        case ProxyError.http(let status):
            return (status, "Google 雲端硬碟回應 \(status)")
        case let error as URLError where [URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code):
            return (503, error.localizedDescription)
        default:
            return (502, error.localizedDescription)
        }
    }

    /// 送出並等 socket 收下（背壓：播放器不讀，這裡就停）
    private func write(_ data: Data?, final: Bool = false) async -> Bool {
        let connection = connection
        return await withCheckedContinuation { cont in
            connection.send(
                content: data,
                contentContext: final ? .finalMessage : .defaultMessage,
                isComplete: final,
                completion: .contentProcessed { error in cont.resume(returning: error == nil) }
            )
        }
    }

    private func respondError(_ status: Int, _ message: String) {
        guard !closed else { return }
        connection.send(content: HTTPResponseHead.error(status, message: message), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.proxy.queue.async { self?.close() }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        serving?.cancel()
        serving = nil
        connection.cancel()
        proxy.remove(self)
    }
}
