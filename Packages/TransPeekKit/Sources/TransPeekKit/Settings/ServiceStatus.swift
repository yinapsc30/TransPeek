import Foundation

/// “测试连接”的状态（S6.2、S7.5）。只保存在内存中。
public enum ConnectionTestState: Sendable, Equatable {
    case idle
    case running
    case success(translation: String, milliseconds: Int)
    case failure(String)
}

/// 翻译服务卡片上的状态（S6.2）。
public enum ServiceStatus: Sendable, Equatable {
    case missingKey
    case missingModel
    case untested
    case testing
    case passed(milliseconds: Int)
    case failed(String)

    /// 优先级：缺少 Key → 未填模型 → 测试中 → 测试失败 → 测试通过 → 尚未测试。
    public static func evaluate(_ profile: TranslationProfile, hasAPIKey: Bool, requiresAPIKey: Bool, test: ConnectionTestState) -> ServiceStatus {
        switch profile.kind {
        case .google:
            if !hasAPIKey { return .missingKey }
        case let .llm(config):
            if requiresAPIKey && !hasAPIKey { return .missingKey }
            if config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingModel }
        }
        switch test {
        case .running: return .testing
        case let .failure(message): return .failed(message)
        case let .success(_, milliseconds): return .passed(milliseconds: milliseconds)
        case .idle: return .untested
        }
    }

    /// 配置本身是否可用（与测试结果无关），用于“开始使用”（S2.2）。
    public static func isConfigured(_ profile: TranslationProfile, hasAPIKey: Bool, requiresAPIKey: Bool) -> Bool {
        switch evaluate(profile, hasAPIKey: hasAPIKey, requiresAPIKey: requiresAPIKey, test: .idle) {
        case .missingKey, .missingModel: false
        default: true
        }
    }

    public var label: String {
        switch self {
        case .missingKey: "缺少 API Key"
        case .missingModel: "未填写模型 ID"
        case .untested: "尚未测试"
        case .testing: "正在测试…"
        case let .passed(milliseconds): "测试通过 · \(milliseconds) ms"
        case let .failed(message): "测试失败：\(message)"
        }
    }

    public var isProblem: Bool {
        switch self {
        case .missingKey, .missingModel, .failed: true
        default: false
        }
    }
}

/// “开始使用”的三个步骤（S2）。
public struct SetupProgress: Sendable, Equatable {
    public var permissionGranted: Bool
    public var serviceConfigured: Bool
    public var hasRegion: Bool

    public init(permissionGranted: Bool, serviceConfigured: Bool, hasRegion: Bool) {
        self.permissionGranted = permissionGranted
        self.serviceConfigured = serviceConfigured
        self.hasRegion = hasRegion
    }

    /// 未完成的步骤数，显示在侧边栏角标上（S1.4）。
    public var pendingCount: Int {
        [permissionGranted, serviceConfigured, hasRegion].filter { !$0 }.count
    }
}
