import Foundation

/// 一行识别结果的角色（ocr-cleanup C1）。
public enum LineRole: Sendable, Equatable {
    /// 需要翻译的正文。
    case message
    /// 只有名字、频道、徽章、时间的行，显示但不翻译。
    case metadata
}

/// 规则过滤：移除界面标签、丢弃乱码行、识别名字/时间行（C1.2–C1.4）。
public struct NoiseFilter: Sendable {
    public init() {}

    /// - Parameter detectsMetadata: 是否识别名字/时间行。启用 LLM 智能整理时交给模型判断，传 `false`（C1.4）。
    /// - Returns: 整理后的文本和角色；`nil` 表示丢弃。
    public func classify(_ text: String, detectsMetadata: Bool) -> (text: String, role: LineRole)? {
        let cleaned = Self.removingUILabels(text)
        guard !cleaned.isEmpty else { return nil }
        // 先判断名字/时间行：时间里的数字和冒号会拉低文字占比，不能先按乱码丢弃
        if detectsMetadata, Self.isMetadata(cleaned) {
            return (cleaned, .metadata)
        }
        guard !Self.isGarbage(cleaned) else { return nil }
        return (cleaned, .message)
    }

    // MARK: - 界面标签（C1.2）

    private static let uiLabelPattern = try! NSRegularExpression(
        pattern: #"[（(]\s*(?:edited|已编辑|已編輯|編集済み|編集済|수정됨)\s*[)）]"#,
        options: [.caseInsensitive]
    )

    static func removingUILabels(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let replaced = uiLabelPattern.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        return TextNormalizer.normalize(replaced)
    }

    // MARK: - 乱码行（C1.3）

    /// 文字字符少于 2 个，或文字字符占非空白字符的比例低于 25%。
    /// 比例不能定得太高：`S> 180K`、`[14:39] Rex: gg` 这类正常消息的文字占比只有 33%–38%。
    static func isGarbage(_ text: String) -> Bool {
        var letters = 0
        var nonSpace = 0
        for character in text where !character.isWhitespace {
            nonSpace += 1
            if character.isLetter { letters += 1 }
        }
        guard nonSpace > 0 else { return true }
        return letters < 2 || Double(letters) / Double(nonSpace) < 0.25
    }

    // MARK: - 名字/时间行（C1.4）

    /// 行尾的时间。也用于从名字行中提取说话人（panel-redesign P5.2）。
    static let trailingTime = try! NSRegularExpression(
        pattern: #"[\[(（]?\s*(?:上午|下午|晚上|凌晨|中午)?\s*\d{1,2}:\d{2}(?::\d{2})?\s*(?:[AaPp]\.?[Mm]\.?)?\s*[\])）]?$"#
    )
    private static let forbiddenCharacters: Set<Character> = [":", "：", ".", "?", "!", "。", "？", "！"]

    static func isMetadata(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = trailingTime.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text)
        else { return false }
        let head = text[..<matchRange.lowerBound].trimmingCharacters(in: .whitespaces)
        if head.isEmpty { return true } // 整行只有时间
        guard !head.contains(where: { forbiddenCharacters.contains($0) }) else { return false }
        let words = head.split(whereSeparator: { $0.isWhitespace })
        guard (1...4).contains(words.count), let first = words.first?.first else { return false }
        return first.isUppercase || first.isNumber || first == "@" || first == "#" || !(first.isASCII)
    }
}
