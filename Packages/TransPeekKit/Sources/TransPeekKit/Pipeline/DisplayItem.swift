import Foundation

/// 从名字行（C3.1）中提取说话人（panel-redesign P5.2）。
public enum SpeakerLabel {
    private static let separators = CharacterSet(charactersIn: "-—–·•|:：").union(.whitespaces)
    /// 时间前的日期词，例如 Discord 的“Today at 21:04”、“昨天 21:04”。
    private static let trailingDay = try! NSRegularExpression(
        pattern: #"(?i)(?:\b(?:today|yesterday)(?:\s+at)?|今天|昨天|前天)\s*$"#
    )

    /// 去掉名字行结尾的时间、日期词和分隔符；只有时间时返回 `nil`。
    public static func name(fromMetadata text: String) -> String? {
        var head = text.trimmingCharacters(in: .whitespaces)
        for pattern in [NoiseFilter.trailingTime, trailingDay] {
            let range = NSRange(head.startIndex..., in: head)
            if let match = pattern.firstMatch(in: head, range: range),
               let matchRange = Range(match.range, in: head) {
                head = String(head[..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        let name = head.trimmingCharacters(in: separators)
        return name.isEmpty ? nil : name
    }
}

/// 面板中显示的一条（panel-redesign P2.3、P3.2、P5）。名字行不单独显示，作为下一条消息的说话人。
public struct DisplayItem: Sendable, Identifiable, Equatable {
    /// 消息行（`.line`）或遗漏标记（`.gapMarker`）。
    public let entry: Entry
    /// 来自紧挨着的上一条名字行（P5.1）。
    public let speaker: String?
    /// 最后一条消息（P2.3、P3.2、P3.3）。
    public let isLatest: Bool

    public var id: UUID { entry.id }

    public init(entry: Entry, speaker: String?, isLatest: Bool) {
        self.entry = entry
        self.speaker = speaker
        self.isLatest = isLatest
    }
}

extension PanelHistory {
    /// 面板中显示的条目：名字行与下一条消息配对，标记最新一条（design.md「说话人与显示条目」）。
    public func displayItems() -> [DisplayItem] {
        Self.displayItems(from: entries)
    }

    static func displayItems(from entries: [Entry]) -> [DisplayItem] {
        let latestID = entries.last { $0.kind == .line && $0.translation != .metadata && $0.translation != .hidden }?.id
        var items: [DisplayItem] = []
        var speaker: String?
        for entry in entries {
            switch entry.kind {
            case .gapMarker:
                // 遗漏的消息之后，名字可能对不上
                speaker = nil
                items.append(DisplayItem(entry: entry, speaker: nil, isLatest: false))
            case .line, .dialogSnapshot:
                switch entry.translation {
                case .metadata:
                    // 连续的名字行以后一条为准；末尾的名字行不显示
                    speaker = SpeakerLabel.name(fromMetadata: entry.original)
                case .hidden:
                    continue
                default:
                    items.append(DisplayItem(entry: entry, speaker: speaker, isLatest: entry.id == latestID))
                    speaker = nil
                }
            }
        }
        return items
    }
}
