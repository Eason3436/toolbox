import SwiftUI

/// 打開「記一筆」時要直接進入的模式
enum AddStart: Equatable {
    case normal, sentence, scan
}

struct OpenAddEntryKey: EnvironmentKey {
    static let defaultValue: (AddStart) -> Void = { _ in }
}

extension EnvironmentValues {
    /// 任何頁面都能叫出「記一筆」（例如首頁的快速記帳按鈕）
    var openAddEntry: (AddStart) -> Void {
        get { self[OpenAddEntryKey.self] }
        set { self[OpenAddEntryKey.self] = newValue }
    }
}
