import Foundation

/// 隨機抽一組
enum Shuffler {
    /// 從 `ids` 去掉 `excluded` 之後隨機抽 `size` 個（不重複）
    static func group(from ids: [String], excluding excluded: Set<String>, size: Int) -> [String] {
        var rng = SystemRandomNumberGenerator()
        return group(from: ids, excluding: excluded, size: size, using: &rng)
    }

    static func group<R: RandomNumberGenerator>(from ids: [String], excluding excluded: Set<String>, size: Int, using rng: inout R) -> [String] {
        var pool = excluded.isEmpty ? ids : ids.filter { !excluded.contains($0) }
        let count = min(max(size, 0), pool.count)
        // 只洗前 count 個（Fisher–Yates 做一半），幾萬張也很快
        for i in 0..<count {
            let j = Int.random(in: i..<pool.count, using: &rng)
            pool.swapAt(i, j)
        }
        return Array(pool.prefix(count))
    }

    /// 整份洗牌（影片頁用）
    static func shuffled(_ ids: [String], excluding excluded: Set<String>) -> [String] {
        ids.filter { !excluded.contains($0) }.shuffled()
    }
}
