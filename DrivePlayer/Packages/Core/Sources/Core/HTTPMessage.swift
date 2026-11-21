import Foundation

/// 本機串流代理用的最小 HTTP/1.1 解析與組裝（只處理 AVPlayer 會送的 GET／HEAD）。
public struct HTTPRequestHead: Sendable, Equatable {
    public var method: String
    public var target: String
    /// 標頭名稱一律小寫
    public var headers: [String: String]

    public static let terminator = Data("\r\n\r\n".utf8)

    /// 從累積的位元組裡解析請求標頭。資料還不完整時回傳 nil。
    /// - Returns: (標頭, 標頭佔用的位元組數)
    public static func parse(_ data: Data) -> (HTTPRequestHead, Int)? {
        guard let end = data.range(of: terminator) else { return nil }
        let headData = data[data.startIndex..<end.lowerBound]
        guard let text = String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .isoLatin1) else {
            return nil
        }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let head = HTTPRequestHead(method: String(requestLine[0]).uppercased(), target: String(requestLine[1]), headers: headers)
        return (head, end.upperBound - data.startIndex)
    }

    public var range: String? { headers["range"] }
}

/// `/stream/{fileId}` 或 `/stream/{fileId}/{任意檔名}`（檔名只是給播放器看副檔名用）
public enum StreamRoute {
    public static let prefix = "/stream/"

    public static func fileId(from target: String) -> String? {
        var path = target
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let id = rest.split(separator: "/").first, !id.isEmpty else { return nil }
        let decoded = String(id).removingPercentEncoding ?? String(id)
        // Drive 的 fileId 只有英數、- 與 _
        guard decoded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return decoded
    }

    public static func path(fileId: String, filename: String? = nil) -> String {
        var p = prefix + fileId
        if let filename, let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) {
            p += "/" + encoded
        }
        return p
    }
}

public struct HTTPResponseHead: Sendable, Equatable {
    public var status: Int
    public var headers: [(String, String)]

    public init(status: Int, headers: [(String, String)] = []) {
        self.status = status
        self.headers = headers
    }

    public static func == (lhs: HTTPResponseHead, rhs: HTTPResponseHead) -> Bool {
        lhs.status == rhs.status && lhs.headers.map { "\($0.0):\($0.1)" } == rhs.headers.map { "\($0.0):\($0.1)" }
    }

    /// 上游（Drive）回應要轉送給播放器的標頭
    public static let forwardedHeaders = [
        "content-type", "content-length", "content-range", "accept-ranges", "last-modified", "etag",
    ]

    /// 從上游的標頭挑出要轉送的；一定加上 Accept-Ranges: bytes
    public static func forwarding(status: Int, upstream: [String: String]) -> HTTPResponseHead {
        var lowered: [String: String] = [:]
        for (k, v) in upstream { lowered[k.lowercased()] = v }
        var headers: [(String, String)] = []
        let names = [
            "content-type": "Content-Type", "content-length": "Content-Length", "content-range": "Content-Range",
            "accept-ranges": "Accept-Ranges", "last-modified": "Last-Modified", "etag": "ETag",
        ]
        for key in forwardedHeaders {
            if let v = lowered[key] { headers.append((names[key]!, v)) }
        }
        if lowered["accept-ranges"] == nil { headers.append(("Accept-Ranges", "bytes")) }
        headers.append(("Connection", "close"))
        return HTTPResponseHead(status: status, headers: headers)
    }

    public static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    public func serialized() -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        return Data(s.utf8)
    }

    /// 沒有內容的錯誤回應
    public static func error(_ status: Int, message: String = "") -> Data {
        let body = Data(message.utf8)
        var head = HTTPResponseHead(status: status, headers: [
            ("Content-Type", "text/plain; charset=utf-8"),
            ("Content-Length", "\(body.count)"),
            ("Connection", "close"),
        ]).serialized()
        head.append(body)
        return head
    }
}

/// `Range: bytes=start-end` 的解析（只處理單一範圍，AVPlayer 不會送多段）
public struct ByteRange: Sendable, Equatable {
    public var start: Int64?
    public var end: Int64?

    public init(start: Int64?, end: Int64?) {
        self.start = start
        self.end = end
    }

    public static func parse(_ header: String?) -> ByteRange? {
        guard let header else { return nil }
        let h = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard h.hasPrefix("bytes=") else { return nil }
        let spec = h.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return nil }
        let start = parts[0].isEmpty ? nil : Int64(parts[0])
        let end = parts[1].isEmpty ? nil : Int64(parts[1])
        if !parts[0].isEmpty && start == nil { return nil }
        if !parts[1].isEmpty && end == nil { return nil }
        if start == nil && end == nil { return nil }
        if let s = start, let e = end, e < s { return nil }
        return ByteRange(start: start, end: end)
    }

    public var headerValue: String {
        "bytes=\(start.map(String.init) ?? "")-\(end.map(String.init) ?? "")"
    }
}
