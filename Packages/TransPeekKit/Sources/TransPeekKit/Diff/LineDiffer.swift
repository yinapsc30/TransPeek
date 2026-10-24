import Foundation

/// 聊天模式的增量结果。
public struct ChatDiff: Sendable, Equatable {
    /// 新出现的行，按从上到下的顺序。
    public var newLines: [String]
    /// 两次识别结果完全没有重叠，可能有消息被遗漏（R7.4）。
    public var possibleGap: Bool

    public static let none = ChatDiff(newLines: [], possibleGap: false)
}

/// 聊天模式下比较相邻两次识别结果，找出新增行（R7.1–R7.4，design.md「LineDiffer」）。
public struct LineDiffer: Sendable {
    public var threshold: Double

    public init(threshold: Double = Similarity.defaultThreshold) {
        self.threshold = threshold
    }

    /// 至少匹配这么多字符才认为两次结果有重叠，避免只靠一条 “gg” 之类的短消息对齐。
    static let minimumMatchedCharacters = 8

    /// 用最长公共子序列（模糊匹配）对齐两次识别结果，新行是 current 中最后一个匹配行之后的部分。
    ///
    /// - 内容上移（新消息出现在底部）：previous 的末尾匹配 current 的开头，之后的行是新行。
    /// - 内容下移（向上翻看历史，R7.3）：current 的末尾也有匹配，没有新行。
    /// - 中间多识别或少识别了几行（OCR 不稳定、回复引用时有时无）：不影响对齐，中间未匹配的行不视为新消息。
    /// - 完全没有可靠的匹配：可能有遗漏（R7.4）。
    public func diff(previous: [String], current: [String]) -> ChatDiff {
        guard !current.isEmpty else { return .none }
        guard !previous.isEmpty else { return ChatDiff(newLines: current, possibleGap: false) }

        let pairs = alignment(previous, current)
        let matchedCharacters = pairs.reduce(0) { $0 + min(previous[$1.0].count, current[$1.1].count) }
        guard let last = pairs.last, matchedCharacters >= Self.minimumMatchedCharacters else {
            return ChatDiff(newLines: current, possibleGap: true)
        }
        return ChatDiff(newLines: Array(current[(last.1 + 1)...]), possibleGap: false)
    }

    /// 返回按顺序匹配的行号对 `(previous 下标, current 下标)`。
    ///
    /// 长度相同的多种对齐中，优先让 current 中靠前的行参与匹配（回溯时先跳过 current 末尾的行），
    /// 这样遇到重复内容时宁可多显示一条，也不漏掉新消息。
    func alignment(_ previous: [String], _ current: [String]) -> [(Int, Int)] {
        let n = previous.count, m = current.count
        var same = [[Bool]](repeating: [Bool](repeating: false, count: m), count: n)
        for i in 0..<n {
            for j in 0..<m {
                same[i][j] = Similarity.isSame(previous[i], current[j], threshold: threshold)
            }
        }
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                lcs[i][j] = same[i - 1][j - 1] ? lcs[i - 1][j - 1] + 1 : max(lcs[i - 1][j], lcs[i][j - 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if same[i - 1][j - 1] && lcs[i][j] == lcs[i - 1][j - 1] + 1 {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if lcs[i][j - 1] >= lcs[i - 1][j] {
                j -= 1
            } else {
                i -= 1
            }
        }
        return pairs.reversed()
    }
}

/// 对话模式的比较（R7.5）。
public enum DialogComparator {
    /// 是否应该用新文本替换当前显示。
    public static func shouldReplace(current: String?, with new: String, threshold: Double = Similarity.defaultThreshold) -> Bool {
        guard !new.isEmpty else { return false }
        guard let current, !current.isEmpty else { return true }
        return !Similarity.isSame(current, new, threshold: threshold)
    }
}
