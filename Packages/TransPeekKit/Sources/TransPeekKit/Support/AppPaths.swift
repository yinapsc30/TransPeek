import Foundation

/// 应用数据目录（design.md「持久化」）。
public enum AppPaths {
    /// `~/Library/Application Support/TransPeek`
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TransPeek", isDirectory: true)
    }

    public static var presets: URL { applicationSupport.appendingPathComponent("presets", isDirectory: true) }

    public static var translationProfiles: URL {
        applicationSupport.appendingPathComponent("translation-profiles.json")
    }
}

/// 统一的 JSON 编解码配置。
enum JSONCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
