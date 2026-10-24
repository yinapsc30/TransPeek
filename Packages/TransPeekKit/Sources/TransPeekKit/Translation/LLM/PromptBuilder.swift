import Foundation

/// LLM 提示词组装（R16.6、R16.8、R16.9、ocr-cleanup C2）。
///
/// system 提示词分两部分：规则部分（内置模板或用户自定义）和输出格式部分（固定追加，用户不可修改，C2.6）。
public enum PromptBuilder {
    /// 内置规则模板，支持 `{source_lang}`、`{target_lang}`、`{app_name}`。输出格式由 `outputFormat` 追加。
    public static let defaultSystemPrompt = """
    You are a translator for game and software user interfaces. Translate each line from {source_lang} to {target_lang}. The text comes from the application "{app_name}" and was captured with OCR, so it may contain small recognition errors; infer the intended meaning.

    Rules:
    - Keep player names, item names inside square brackets, numbers, price abbreviations (such as 180K or 1.5m) and trade prefixes (such as S>, B>, T>) unchanged.
    - Keep the tone short and casual, matching in-game chat. Do not explain, do not add anything.
    - Use the "context" lines only to understand the conversation. Do not translate them.
    - If a line is already in {target_lang} or cannot be translated, return it unchanged.
    """

    /// 支持的变量，用于设置界面提示。
    public static let variables = ["{source_lang}", "{target_lang}", "{app_name}"]

    /// 规则部分：替换变量。
    public static func system(template: String, source: Language?, target: Language, appName: String) -> String {
        template
            .replacingOccurrences(of: "{source_lang}", with: source?.englishName ?? "the detected source language")
            .replacingOccurrences(of: "{target_lang}", with: target.englishName)
            .replacingOccurrences(of: "{app_name}", with: appName.isEmpty ? "unknown" : appName)
    }

    /// 完整的 system 提示词：规则部分 + 输出格式。
    public static func fullSystem(template: String, source: Language?, target: Language, appName: String, classifiesLines: Bool) -> String {
        system(template: template, source: source, target: target, appName: appName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n" + outputFormat(classifiesLines: classifiesLines)
    }

    /// 输出格式说明（C2.2、C2.6）。
    public static func outputFormat(classifiesLines: Bool) -> String {
        if classifiesLines {
            return """
            Output format:
            The lines were captured from the screen with OCR, so some of them are not messages. Give every line a "type":
            - "message": a chat message or any content the user wants to read. Translate it into "text".
            - "name": only a player name, channel, badge or timestamp (for example "Haka GLUE 14:39"). Set "text" to "".
            - "ui": a button, label, menu item, or OCR noise from icons and avatars. Set "text" to "".
            Output JSON only, in the form {"translations": [{"id": 1, "type": "message", "text": "..."}]}, with exactly one item for every input id.
            """
        }
        return """
        Output format:
        Output JSON only, in the form {"translations": [{"id": 1, "text": "..."}]}, with exactly one item for every input id.
        """
    }

    private struct UserMessage: Encodable {
        struct Line: Encodable {
            let id: Int
            let text: String
        }

        let context: [ContextPair]?
        let lines: [Line]
    }

    /// user 消息：最近 `contextLimit` 条上下文 + 从 1 开始编号的待翻译行。
    public static func user(lines: [String], context: [ContextPair], contextLimit: Int) -> String {
        let trimmedContext = contextLimit > 0 ? Array(context.suffix(contextLimit)) : []
        let message = UserMessage(
            context: trimmedContext.isEmpty ? nil : trimmedContext,
            lines: lines.enumerated().map { UserMessage.Line(id: $0.offset + 1, text: $0.element) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(message)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `max_tokens` 估算：按输入字符数 × 4，限制在 256...4096。
    public static func maxTokens(for lines: [String]) -> Int {
        let characters = lines.reduce(0) { $0 + $1.count + 16 } // 16：每行 JSON 结构的开销
        return min(max(characters * 4, 256), 4096)
    }
}
