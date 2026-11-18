import Foundation

/// @AppStorage 的 key 與預設值
enum SettingsKey {
    static let groupSize = "groupSize"
    static let excludeViewed = "excludeViewed"
    static let excludeFavorites = "excludeFavorites"
    static let hapticsOn = "hapticsOn"
    static let photoFilter = "photoFilter"
}

enum SettingsDefault {
    static let groupSize = 15
    static let groupSizes = [5, 10, 15, 20, 30, 50]
}
