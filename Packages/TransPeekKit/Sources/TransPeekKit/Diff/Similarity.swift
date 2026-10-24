import Foundation

/// 文本相似度（R7.2）。
public enum Similarity {
    /// 默认判定为同一行的阈值。
    public static let defaultThreshold = 0.85

    /// `1 - levenshtein(a, b) / max(len(a), len(b))`，忽略大小写，取值 0...1。两个空字符串视为完全相同。
    public static func ratio(_ a: String, _ b: String) -> Double {
        let lhs = Array(a.lowercased())
        let rhs = Array(b.lowercased())
        let longest = max(lhs.count, rhs.count)
        guard longest > 0 else { return 1 }
        if lhs == rhs { return 1 }
        return 1 - Double(levenshtein(lhs, rhs)) / Double(longest)
    }

    public static func isSame(_ a: String, _ b: String, threshold: Double = defaultThreshold) -> Bool {
        ratio(a, b) >= threshold
    }

    /// 编辑距离，两行滚动数组实现。
    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
