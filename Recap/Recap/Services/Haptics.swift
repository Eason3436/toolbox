import UIKit

/// 觸覺回饋：模擬實體按鍵的手感。App 在背景時系統不會震動，呼叫也不會出錯。
@MainActor
enum Haptics {
    /// 按下錄音鍵：沉穩的一下，像按下實體錄音鍵
    static func recordStart() {
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        heavy.impactOccurred(intensity: 1.0)
        // 接著一個輕微的「卡榫」回彈
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.45)
        }
    }

    /// 停止：硬脆的兩下，像把開關扳回去
    static func recordStop() {
        let rigid = UIImpactFeedbackGenerator(style: .rigid)
        rigid.impactOccurred(intensity: 0.9)
        Task {
            try? await Task.sleep(for: .milliseconds(110))
            rigid.impactOccurred(intensity: 0.6)
        }
    }

    /// 暫停／繼續：一下中等力道
    static func toggle() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
    }

    /// 一般按鈕
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 柔和的觸碰（播放器、捲動到新內容）
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
    }

    /// 切換選項、分頁、星期
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
