import Foundation
@preconcurrency import GoogleSignIn
import Observation
import UIKit

enum AuthError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case missingScope
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "這個版本沒有設定 Google Client ID（GitHub Secrets 的 GOOGLE_CLIENT_ID）"
        case .notSignedIn: "尚未登入 Google，請到「設定」登入"
        case .missingScope: "沒有取得讀取 Google 雲端硬碟的權限，請重新登入並勾選允許"
        case .cancelled: "已取消登入"
        case .failed(let message): "Google 登入失敗：\(message)"
        }
    }
}

/// Google 登入。啟動時 restorePreviousSignIn()，每次呼叫 API 前 refreshTokensIfNeeded()。
@MainActor
@Observable
final class GoogleAuthService {
    static let driveScope = "https://www.googleapis.com/auth/drive.readonly"

    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn
    }

    private(set) var state: State = .restoring
    private(set) var email: String?
    private(set) var displayName: String?
    private(set) var hasDriveScope = false
    let isConfigured: Bool

    /// 給 Drive API 與串流代理用的 token 快取（不在主執行緒上）
    @ObservationIgnored private(set) var tokens: AccessTokenStore!

    init() {
        if let clientID = AppConfig.googleClientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            isConfigured = true
        } else {
            isConfigured = false
        }
        tokens = AccessTokenStore { [self] in try await self.freshToken() }
    }

    // MARK: - 登入流程

    func restore() async {
        guard isConfigured, GIDSignIn.sharedInstance.hasPreviousSignIn() else {
            state = .signedOut
            return
        }
        do {
            let info: UserInfo = try await withCheckedThrowingContinuation { cont in
                GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
                    if let user { cont.resume(returning: UserInfo(user)) }
                    else { cont.resume(throwing: Self.map(error)) }
                }
            }
            apply(info)
        } catch {
            state = .signedOut
        }
    }

    func signIn() async throws {
        guard isConfigured else { throw AuthError.notConfigured }
        guard let presenter = UIApplication.shared.topViewController else { throw AuthError.failed("找不到畫面") }
        let info: UserInfo = try await withCheckedThrowingContinuation { cont in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter, hint: nil, additionalScopes: [Self.driveScope]
            ) { result, error in
                if let user = result?.user { cont.resume(returning: UserInfo(user)) }
                else { cont.resume(throwing: Self.map(error)) }
            }
        }
        apply(info)
        await tokens.clear()
        if !info.hasDriveScope { throw AuthError.missingScope }
    }

    func signOut() async {
        GIDSignIn.sharedInstance.signOut()
        await tokens.clear()
        email = nil
        displayName = nil
        hasDriveScope = false
        state = .signedOut
    }

    func handle(_ url: URL) {
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    /// 取得有效的 access token（快過期時 Google SDK 會自動換新）
    func freshToken() async throws -> AccessToken {
        guard isConfigured else { throw AuthError.notConfigured }
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            if state == .signedIn { state = .signedOut }
            throw AuthError.notSignedIn
        }
        let token: AccessToken = try await withCheckedThrowingContinuation { cont in
            user.refreshTokensIfNeeded { user, error in
                if let user {
                    cont.resume(returning: AccessToken(value: user.accessToken.tokenString, expiry: user.accessToken.expirationDate))
                } else {
                    cont.resume(throwing: Self.map(error))
                }
            }
        }
        return token
    }

    // MARK: - 內部

    private struct UserInfo: Sendable {
        var email: String?
        var name: String?
        var hasDriveScope: Bool

        init(_ user: GIDGoogleUser) {
            email = user.profile?.email
            name = user.profile?.name
            hasDriveScope = user.grantedScopes?.contains(GoogleAuthService.driveScope) ?? false
        }
    }

    private func apply(_ info: UserInfo) {
        email = info.email
        displayName = info.name
        hasDriveScope = info.hasDriveScope
        state = .signedIn
    }

    nonisolated private static func map(_ error: Error?) -> AuthError {
        guard let error else { return .failed("未知錯誤") }
        let ns = error as NSError
        if ns.domain == kGIDSignInErrorDomain {
            switch ns.code {
            case GIDSignInError.canceled.rawValue: return .cancelled
            case GIDSignInError.hasNoAuthInKeychain.rawValue: return .notSignedIn
            default: break
            }
        }
        if ns.domain == NSURLErrorDomain { return .failed("網路連線有問題") }
        return .failed(error.localizedDescription)
    }
}

struct AccessToken: Sendable {
    var value: String
    var expiry: Date?
}

/// access token 快取：還有 2 分鐘以上才過期就直接用，不然向 Google SDK 要新的。
/// 同時有很多請求（串流代理）時只會問一次。
actor AccessTokenStore {
    private let fetch: @Sendable () async throws -> AccessToken
    private var cached: AccessToken?
    private var inFlight: Task<AccessToken, Error>?

    init(fetch: @escaping @Sendable () async throws -> AccessToken) {
        self.fetch = fetch
    }

    func token(forceRefresh: Bool = false) async throws -> String {
        if forceRefresh { cached = nil }
        if let cached, let expiry = cached.expiry, expiry.timeIntervalSinceNow > 120 {
            return cached.value
        }
        if let inFlight { return try await inFlight.value.value }
        let task = Task { try await fetch() }
        inFlight = task
        defer { inFlight = nil }
        let token = try await task.value
        cached = token
        return token.value
    }

    func clear() {
        cached = nil
    }
}
