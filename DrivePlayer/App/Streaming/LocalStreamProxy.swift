import Core
import Foundation
import Network

/// 本機串流代理：AVPlayer（之後的 mpv 也一樣）播放 `http://127.0.0.1:{port}/stream/{fileId}`，
/// 這裡每個請求都拿**當下有效的** token 轉送到 Drive，並原樣轉送 Range。
///
/// 為什麼要代理：Google 的 access token 一小時就過期，直接把 Authorization 塞進 AVURLAsset，
/// 長片播到後半段會收到 401 而中斷。
///
/// - 只聽 loopback，外部連不進來
/// - 回應分段串流，送出去還沒被吃掉的資料超過 `highWater` 就暫停下載（不會整部讀進記憶體）
/// - 一個連線只處理一個請求（`Connection: close`），AVPlayer 會自己開新的連線
/// - 回到前景時呼叫 `ensureRunning()`，被系統關掉的 listener 會在同一個 port 重開
final class LocalStreamProxy: @unchecked Sendable {
    typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    /// 送出但還沒寫進 socket 的位元組超過這個數就暫停下載，低於 `lowWater` 再繼續
    static let highWater = 8 * 1024 * 1024
    static let lowWater = 2 * 1024 * 1024

    let tokenProvider: TokenProvider
    let upstreamURL: @Sendable (String) -> URL

    /// 所有狀態都只在這個 queue 上讀寫
    let queue = DispatchQueue(label: "DrivePlayer.LocalStreamProxy", qos: .userInitiated)
    let session: URLSession

    private var listener: NWListener?
    private var listenerPort: NWEndpoint.Port?
    private var waiting: [CheckedContinuation<UInt16, Error>] = []
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]

    init(tokenProvider: @escaping TokenProvider, upstreamURL: @escaping @Sendable (String) -> URL = { DriveAPI.mediaURL(fileId: $0) }) {
        self.tokenProvider = tokenProvider
        self.upstreamURL = upstreamURL
        let ops = OperationQueue()
        ops.maxConcurrentOperationCount = 1
        ops.underlyingQueue = queue
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config, delegate: nil, delegateQueue: ops)
    }

    // MARK: - 對外

    /// 播放用的網址（代理沒在跑會先啟動）
    func streamURL(fileId: String, filename: String? = nil) async throws -> URL {
        let port = try await ensureRunning()
        return URL(string: "http://127.0.0.1:\(port)" + StreamRoute.path(fileId: fileId, filename: filename))!
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

/// 一個 AVPlayer 的連線（一個請求）。所有方法都在 proxy.queue 上執行。
private final class ProxyConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private unowned let proxy: LocalStreamProxy
    private var buffer = Data()
    private var request: HTTPRequestHead?
    private var fileId = ""
    private var task: URLSessionDataTask?
    private var retried = false
    private var headSent = false
    private var closed = false
    private var inFlight = 0
    private var suspended = false

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
        request = head
        guard head.method == "GET" || head.method == "HEAD" else {
            respondError(405, "只支援 GET／HEAD")
            return
        }
        guard let id = StreamRoute.fileId(from: head.target) else {
            respondError(404, "找不到")
            return
        }
        fileId = id
        fetchTokenAndStart(forceRefresh: false)
    }

    private func fetchTokenAndStart(forceRefresh: Bool) {
        let provider = proxy.tokenProvider
        let queue = proxy.queue
        Task {
            do {
                let token = try await provider(forceRefresh)
                queue.async { self.startUpstream(token: token) }
            } catch {
                queue.async { self.respondError(401, error.localizedDescription) }
            }
        }
    }

    // MARK: 轉送到 Drive

    private func startUpstream(token: String) {
        guard !closed, let request else { return }
        var upstream = URLRequest(url: proxy.upstreamURL(fileId))
        upstream.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if request.method == "HEAD" {
            // HEAD：只要 1 個位元組，從 Content-Range 讀出總長度
            upstream.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        } else if let range = request.range, ByteRange.parse(range) != nil {
            upstream.setValue(range, forHTTPHeaderField: "Range")
        }
        let task = proxy.session.dataTask(with: upstream)
        task.delegate = self
        self.task = task
        task.resume()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard dataTask === task, !closed else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 502

        if status == 401, !retried {
            // token 剛好過期：換新的再試一次
            retried = true
            task = nil
            completionHandler(.cancel)
            fetchTokenAndStart(forceRefresh: true)
            return
        }
        guard (200..<300).contains(status) else {
            completionHandler(.cancel)
            task = nil
            if status == 416, let cr = http?.value(forHTTPHeaderField: "Content-Range") {
                var head = HTTPResponseHead(status: 416, headers: [("Content-Range", cr), ("Content-Length", "0"), ("Connection", "close")]).serialized()
                head.append(Data())
                sendAndClose(head)
            } else {
                respondError(status, "Google 雲端硬碟回應 \(status)")
            }
            return
        }

        var upstreamHeaders: [String: String] = [:]
        for name in HTTPResponseHead.forwardedHeaders {
            if let v = http?.value(forHTTPHeaderField: name) { upstreamHeaders[name] = v }
        }

        if request?.method == "HEAD" {
            completionHandler(.cancel)
            task = nil
            var headers: [String: String] = ["accept-ranges": "bytes"]
            if let type = upstreamHeaders["content-type"] { headers["content-type"] = type }
            if let cr = upstreamHeaders["content-range"], let total = cr.split(separator: "/").last {
                headers["content-length"] = String(total)
            }
            sendAndClose(HTTPResponseHead.forwarding(status: 200, upstream: headers).serialized())
            return
        }

        let head = HTTPResponseHead.forwarding(status: status, upstream: upstreamHeaders)
        headSent = true
        send(head.serialized())
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task, !closed else { return }
        send(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task, !closed else { return }
        self.task = nil
        if let error {
            if headSent {
                close()
            } else {
                let offline = (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains($0.code) } ?? false
                respondError(offline ? 503 : 502, error.localizedDescription)
            }
            return
        }
        // 全部送完：等 socket 寫完再關
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    // MARK: 寫回播放器（有背壓）

    private func send(_ data: Data) {
        let count = data.count
        inFlight += count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.inFlight -= count
            if error != nil {
                self.close()
                return
            }
            if self.suspended, self.inFlight < LocalStreamProxy.lowWater {
                self.suspended = false
                self.task?.resume()
            }
        })
        if !suspended, inFlight > LocalStreamProxy.highWater {
            suspended = true
            task?.suspend()
        }
    }

    private func respondError(_ status: Int, _ message: String) {
        sendAndClose(HTTPResponseHead.error(status, message: message))
    }

    private func sendAndClose(_ data: Data) {
        guard !closed else { return }
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel()
        task = nil
        connection.cancel()
        proxy.remove(self)
    }
}
