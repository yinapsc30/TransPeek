import Foundation

/// 面板中的条目历史，只保存在内存中（R7.6、R15.2）。
public struct PanelHistory: Sendable, Equatable {
    /// 历史条目（聊天/单次模式的行、对话模式的历史快照、遗漏标记），按时间顺序。
    public private(set) var entries: [Entry] = []
    /// 对话模式当前显示的文本。
    public private(set) var currentDialog: Entry?
    public var limit: Int {
        didSet { trim() }
    }

    public init(limit: Int = 500) {
        self.limit = max(1, limit)
    }

    /// 计入“↓ N 条新消息”的条目：消息行，不含遗漏标记和名字/时间行（ocr-cleanup C3.2）。
    private static func countsAsNew(_ entry: Entry) -> Bool {
        entry.kind == .line && entry.translation != .metadata
    }

    /// 应用流水线事件，返回新增的消息条数（用于“↓ N 条新消息”）。
    /// 条目被判为界面文字（`.hidden`）时删除该条目并返回 `-1`（C2.3、C3.2）。
    @discardableResult
    public mutating func apply(_ event: PipelineEvent) -> Int {
        switch event {
        case let .append(newEntries):
            entries.append(contentsOf: newEntries)
            trim()
            return newEntries.filter(Self.countsAsNew).count
        case let .replaceAll(newEntries):
            entries = newEntries
            trim()
            return newEntries.filter(Self.countsAsNew).count
        case let .update(entryID, .hidden):
            if currentDialog?.id == entryID {
                currentDialog = nil
                return 0
            }
            guard let index = entries.lastIndex(where: { $0.id == entryID }) else { return 0 }
            let removed = entries.remove(at: index)
            return Self.countsAsNew(removed) ? -1 : 0
        case let .dialog(entry):
            if let currentDialog {
                entries.append(currentDialog)
                trim()
            }
            currentDialog = entry
            return 0
        case let .update(entryID, state):
            if currentDialog?.id == entryID {
                currentDialog?.translation = state
            } else if let index = entries.lastIndex(where: { $0.id == entryID }) {
                entries[index].translation = state
            }
            return 0
        }
    }

    public mutating func clear() {
        entries.removeAll()
        currentDialog = nil
    }

    public func entry(id: UUID) -> Entry? {
        if currentDialog?.id == id { return currentDialog }
        return entries.last { $0.id == id }
    }

    /// “复制全部”的纯文本（R11.4）。
    public func plainText(includeOriginal: Bool) -> String {
        var all = entries
        if let currentDialog { all.append(currentDialog) }
        return all.compactMap { entry -> String? in
            switch entry.kind {
            case .gapMarker:
                return "……可能有遗漏……"
            case .line, .dialogSnapshot:
                let translated = entry.translation.translatedText ?? entry.original
                guard includeOriginal, translated != entry.original else { return translated }
                return "\(translated)\n\(entry.original)"
            }
        }
        .joined(separator: "\n")
    }

    private mutating func trim() {
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }
}
