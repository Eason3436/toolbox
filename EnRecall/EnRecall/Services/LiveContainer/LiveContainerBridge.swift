import Foundation

/// App 裝在 LiveContainer 裡跑時，跟 LiveContainer 拿資料（它自己加在 NSUserDefaults 上的類別方法）。
/// 不在 LiveContainer 裡就全部是 nil／false
enum LiveContainerBridge {
    /// LiveContainer 的程式碼跟 App 在同一個程序裡
    static var isInside: Bool {
        NSClassFromString("LCSharedUtils") != nil
            && !(Bundle.main.bundleIdentifier ?? "").hasPrefix("com.kdt.livecontainer")
    }

    /// LiveContainer 真正的 App Group 資料夾（小工具在另一個程序，只讀得到這裡）
    static var appGroupURL: URL? {
        guard isInside, let path = userDefaultsString("lcAppGroupPath"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 開這個 LiveContainer 用的網址 scheme（livecontainer、livecontainer2…）
    static var urlScheme: String? { isInside ? userDefaultsString("lcAppUrlScheme") : nil }

    /// App 在 LiveContainer 裡的資料夾名稱（點小工具時用來打開這個 App）
    static var bundleName: String { Bundle.main.bundleURL.lastPathComponent }

    /// 資料容器的資料夾名稱
    static var containerName: String { URL(fileURLWithPath: NSHomeDirectory()).lastPathComponent }

    private static func userDefaultsString(_ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        let defaultsClass: AnyObject = UserDefaults.self
        guard defaultsClass.responds(to: selector) else { return nil }
        return defaultsClass.perform(selector)?.takeUnretainedValue() as? String
    }
}
