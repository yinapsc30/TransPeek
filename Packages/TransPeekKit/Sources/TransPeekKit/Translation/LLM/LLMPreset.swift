import Foundation

/// LLM 服务商预设（R16.1）。不包含任何模型名称，模型 ID 由用户手动输入（R16.4）。
public struct LLMPreset: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let `protocol`: LLMProtocol
    /// “自定义”预设为空字符串。
    public let baseURL: String
    public let requiresAPIKey: Bool
    /// 服务商的模型文档链接，“自定义”预设没有。
    public let modelsDocURL: URL?
    /// 是否在请求中使用 `response_format: {"type": "json_object"}`。
    public let supportsJSONMode: Bool
    /// 显示在配置页的提示。
    public let note: String?

    public static let customID = "custom"
}

/// 预设列表，打包在 `Resources/LLMPresets.json`，方便社区通过 PR 更新。
public struct LLMPresetCatalog: Sendable {
    public let presets: [LLMPreset]

    public init(presets: [LLMPreset]) {
        self.presets = presets
    }

    public static let bundled: LLMPresetCatalog = {
        guard let url = Bundle.module.url(forResource: "LLMPresets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let presets = try? JSONDecoder().decode([LLMPreset].self, from: data)
        else {
            assertionFailure("LLMPresets.json 缺失或格式错误")
            return LLMPresetCatalog(presets: [])
        }
        return LLMPresetCatalog(presets: presets)
    }()

    public func preset(id: String) -> LLMPreset? {
        presets.first { $0.id == id }
    }

    /// 未知预设按“自定义”处理。
    public func presetOrCustom(id: String) -> LLMPreset? {
        preset(id: id) ?? preset(id: LLMPreset.customID)
    }

    /// 用预设生成一个新的配置（模型 ID 留空，等待用户填写）。
    public func makeConfig(presetID: String) -> LLMConfig? {
        guard let preset = preset(id: presetID) else { return nil }
        return LLMConfig(
            presetID: preset.id,
            protocolKind: preset.protocol,
            baseURL: URL(string: preset.baseURL) ?? URL(string: "https://")!,
            model: ""
        )
    }
}
