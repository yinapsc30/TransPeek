import Foundation

/// 解析 LLM 返回的翻译结果（R16.8）。
public enum ResponseParser {
    /// 返回 id（1...count）到译文的映射，只包含消息行。
    public static func parse(_ raw: String, count: Int) -> [Int: String] {
        parseOutputs(raw, count: count).compactMapValues(\.text)
    }

    /// 返回 id 到结果的映射，包含智能整理标注的类型（ocr-cleanup C2.2–C2.4）。
    /// `type` 为 `name` → `.metadata`，`ui` → `.hidden`，缺失或未知 → 按消息处理（需要有 `text`）。
    /// 缺失、重复（取第一个）、越界的 id 都会被忽略，由调用方逐行重试。
    public static func parseOutputs(_ raw: String, count: Int) -> [Int: TranslationOutput] {
        guard count > 0, let json = extractJSON(from: raw),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        else { return [:] }

        let items: [Any]
        if let dictionary = object as? [String: Any] {
            if let translations = dictionary["translations"] as? [Any] {
                items = translations
            } else if count == 1, let output = output(from: dictionary) {
                return [1: output] // 单行请求时部分模型直接返回一个对象
            } else {
                return [:]
            }
        } else if let array = object as? [Any] {
            items = array
        } else {
            return [:]
        }

        var result: [Int: TranslationOutput] = [:]
        // 纯字符串数组且条数一致时按顺序对应
        if items.count == count, items.allSatisfy({ $0 is String }) {
            for (index, item) in items.enumerated() {
                if let text = item as? String { result[index + 1] = .translated(text) }
            }
            return result
        }
        for item in items {
            guard let dictionary = item as? [String: Any],
                  let id = intValue(dictionary["id"]),
                  (1...count).contains(id),
                  result[id] == nil,
                  let output = output(from: dictionary)
            else { continue }
            result[id] = output
        }
        return result
    }

    private static func output(from dictionary: [String: Any]) -> TranslationOutput? {
        switch (dictionary["type"] as? String)?.lowercased() {
        case "name", "speaker", "metadata", "meta", "timestamp":
            return .metadata
        case "ui", "noise", "label":
            return .hidden
        default:
            guard let text = (dictionary["text"] ?? dictionary["translation"]) as? String else { return nil }
            return .translated(text)
        }
    }

    /// 去掉 Markdown 代码块标记，取第一个完整的 JSON 对象或数组。
    static func extractJSON(from raw: String) -> String? {
        let characters = Array(raw)
        guard let start = characters.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<characters.count {
            let character = characters[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return String(characters[start...index]) }
            default: break
            }
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let string as String: Int(string.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
}
