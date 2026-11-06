import CryptoKit
import Foundation

/// Swift 移植自 `mi_fitness_mcp/adapters/mi_fitness_cloud.py` 的加密原語。
///
/// 小米健康雲用一套“非對稱登入 + RC4 流加密 + SHA1 簽名”保護請求體：
/// - 登入後用 `ssecurity` 派生 `signed_nonce`，作為 RC4 金鑰對請求引數加密；
/// - 同時用 SHA1 生成簽名，防止篡改。
/// 這裡逐函式對應 Python 實現，並用同一套測試向量驗證行為一致。
enum MiCrypto {
    /// 標準 RC4 流加密（Python `_rc4_crypt`），丟棄前 1024 位元組金鑰流。
    /// - Parameters:
    ///   - key: RC4 金鑰（即 signed_nonce 原始位元組）
    ///   - payload: 待加密資料
    /// - Returns: 與明文等長的密文位元組
    static func rc4Crypt(key: [UInt8], payload: [UInt8]) -> [UInt8] {
        var s = Array(UInt8(0)...UInt8(255))
        var j = 0
        let keyLen = key.count
        guard keyLen > 0 else { return payload }
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % keyLen])) % 256
            s.swapAt(i, j)
        }
        var i = 0
        j = 0
        func nextByte() -> UInt8 {
            i = (i + 1) % 256
            j = (j + Int(s[i])) % 256
            s.swapAt(i, j)
            return s[(Int(s[i]) + Int(s[j])) % 256]
        }
        for _ in 0..<1024 { _ = nextByte() }
        return payload.map { $0 ^ nextByte() }
    }

    /// 生成 nonce（Python `_gen_nonce`）：8 位元組隨機數 + 4 位元組大端“(當前秒 / 60)”。
    static func genNonce(now: Date = Date()) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { raw[i] = UInt8.random(in: 0...255) }
        let minutes = UInt32(now.timeIntervalSince1970 / 60)
        withUnsafeBytes(of: minutes.bigEndian) { raw.append(contentsOf: $0) }
        return raw
    }

    /// 由 ssecurity 與 nonce 派生簽名金鑰（Python `_gen_signed_nonce`）：
    /// `SHA256(ssecurity || nonce)`，返回原始 32 位元組。
    static func genSignedNonce(ssecurity: [UInt8], nonce: [UInt8]) -> [UInt8] {
        var data = Data(ssecurity)
        data.append(contentsOf: nonce)
        return Array(SHA256.hash(data: data))
    }

    /// 生成請求籤名（Python `_gen_signature`）：
    /// base = `METHOD&path&data=<data>[&rc4_hash__=<rc4>]&<b64(signed_nonce)>`
    /// 返回 `SHA1(base)` 的 Base64。
    static func genSignature(
        method: String,
        path: String,
        values: [String: String],
        signedNonce: [UInt8]
    ) -> String {
        var base = method + "&" + path + "&data=" + values["data"]!
        if let rc4Hash = values["rc4_hash__"] {
            base += "&rc4_hash__=" + rc4Hash
        }
        base += "&" + Data(signedNonce).base64EncodedString()
        let digest = Insecure.SHA1.hash(data: Data(base.utf8))
        return Data(digest).base64EncodedString()
    }
}
