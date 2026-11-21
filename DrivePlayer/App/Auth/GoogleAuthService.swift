import Foundation
@preconcurrency import GoogleSignIn
import Observation
import UIKit

enum AuthError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case missingScope
    case cancelled
    case network
    case expired
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "這個安裝檔編譯時沒有 Google Client ID，所以還不能登入。請在 Config/App.xcconfig 填上 Google Client ID，重新編譯後安裝新的 IPA。"
        case .notSignedIn: "尚未登入 Google，請到「設定」登入"
        case .missingScope: "沒有取得讀取 Google 雲端硬碟的權限，請重新登入並勾選允許"
        case .cancelled: "已取消登入"
        case .network: "網路連線有問題，無法更新 Google 登入"
        case .expired: "Google 登入已失效，請到「設定」重新登入"
        case .failed(let message): "Google 登入失敗：\(message)"
        }
    }
}

/// Google 登入。啟動時 restorePreviousSignIn()，每次呼叫 API 前 refreshTokensIfNeeded()。
@MainActor
@Observable
final class GoogleAuthService {
    nonisolated static let driveScope = "https://www.googleapis.com/auth/drive.readonly"

    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn
    }

    private(set) var state: State = .restoring
    private(set) var email: String?
    private(set) var displayName: String?
    private(set) var hasDriveScope = false
    /// 原本有登入，但 token 換不到了（撤銷授權、測試中的 OAuth 7 天到期）
    private(set) var sessionExpired = false
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
        sessionExpired = false
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
        do {
            return try await withCheckedThrowingContinuation { cont in
                user.refreshTokensIfNeeded { user, error in
                    if let user {
                        cont.resume(returning: AccessToken(value: user.accessToken.tokenString, expiry: user.accessToken.expirationDate))
                    } else {
                        cont.resume(throwing: Self.map(error))
                    }
                }
            }
        } catch AuthError.network {
            throw AuthError.network
        } catch {
            // 換不到 token 而且不是網路問題：要重新登入
            sessionExpired = true
            state = .signedOut
            throw AuthError.expired
        }
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
        sessionExpired = false
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
        if ns.domain == NSURLErrorDomain { return .network }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain { return .network }
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
