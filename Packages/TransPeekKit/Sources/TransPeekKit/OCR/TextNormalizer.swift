import Foundation

/// 识别文本归一化（R6.5）。
public enum TextNormalizer {
    /// 单独出现时视为噪声的符号（常见于边框、分隔线、图标被误识别）。
    static let noiseCharacters: Set<Character> = ["|", "¦", "‖", "•", "·", "・", "*", "_", "~", "`", "'", "\"", "^", "°", "¤"]

    /// 折叠空白（含全角空格），去除首尾由噪声符号组成的孤立片段。
    public static func normalize(_ text: String) -> String {
        var tokens = text
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        while let first = tokens.first, isNoise(first) { tokens.removeFirst() }
        while let last = tokens.last, isNoise(last) { tokens.removeLast() }
        return tokens.joined(separator: " ")
    }

    static func isNoise(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { noiseCharacters.contains($0) }
    }
}

/// 区域的忽略规则（R4.8）。无效的正则会被跳过并记录在 `invalidPatterns` 中。
public struct IgnoreRules: Sendable {
    private let expressions: [NSRegularExpression]
    public let invalidPatterns: [String]

    public init(patterns: [String]) {
        var expressions: [NSRegularExpression] = []
        var invalid: [String] = []
        for pattern in patterns where !pattern.isEmpty {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                expressions.append(expression)
            } else {
                invalid.append(pattern)
            }
        }
        self.expressions = expressions
        self.invalidPatterns = invalid
    }

    public static func isValid(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }

    public var isEmpty: Bool { expressions.isEmpty }

    /// 移除所有匹配片段后重新归一化，结果可能为空。
    public func apply(to text: String) -> String {
        guard !expressions.isEmpty else { return text }
        var result = text
        for expression in expressions {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
        }
        return TextNormalizer.normalize(result)
    }
}
