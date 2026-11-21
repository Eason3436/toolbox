import Core
import Foundation

enum DriveError: LocalizedError {
    case unauthorized
    case offline
    case notFound
    case server(Int, String?)
    case auth(AuthError)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Google 登入已失效，請到「設定」重新登入"
        case .offline: "沒有網路連線，請檢查網路後再試一次"
        case .notFound: "找不到這個檔案或資料夾（可能已被刪除或移動）"
        case .server(let code, let message): "Google 雲端硬碟回應錯誤（\(code)）\(message.map { "：\($0)" } ?? "")"
        case .auth(let e): e.errorDescription
        case .other(let message): message
        }
    }

    static func from(_ error: Error) -> DriveError {
        if let e = error as? DriveError { return e }
        if let e = error as? AuthError { return e == .network ? .offline : .auth(e) }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            default:
                return .other("網路錯誤：\(e.localizedDescription)")
            }
        }
        return .other(error.localizedDescription)
    }
}

/// Google Drive v3 API（只讀）
final class DriveClient: Sendable {
    let tokens: AccessTokenStore
    private let session: URLSession

    init(tokens: AccessTokenStore) {
        self.tokens = tokens
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// 列出資料夾裡的檔案與子資料夾（自動翻頁）
    func list(folderId: String) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var pageToken: String?
        repeat {
            let data = try await get(DriveAPI.listURL(folderId: folderId, pageToken: pageToken))
            let page = try JSONDecoder().decode(DriveFileList.self, from: data)
            all.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    func file(id: String) async throws -> DriveFile {
        let data = try await get(DriveAPI.fileURL(fileId: id))
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    /// 帶 token 的 GET；401 時換新 token 重試一次
    private func get(_ url: URL) async throws -> Data {
        do {
            for attempt in 0..<2 {
                let token = try await tokens.token(forceRefresh: attempt > 0)
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200..<300: return data
                case 401 where attempt == 0: continue
                case 401: throw DriveError.unauthorized
                case 404: throw DriveError.notFound
                default:
                    let message = (try? JSONDecoder().decode(GoogleAPIError.self, from: data))?.error.message
                    throw DriveError.server(status, message)
                }
            }
            throw DriveError.unauthorized
        } catch {
            throw DriveError.from(error)
        }
    }
}
