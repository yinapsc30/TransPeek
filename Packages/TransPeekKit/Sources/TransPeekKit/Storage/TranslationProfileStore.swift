import Foundation
import os

/// 读写 `translation-profiles.json`（design.md「持久化」）。API Key 不写入文件，只存在 SecretStore 中。
public final class TranslationProfileStore: Sendable {
    /// 配置变更时发出，`object` 为 `TranslationProfileStore`。
    public static let didChangeNotification = Notification.Name("TransPeekTranslationProfilesDidChange")

    private struct FileContents: Codable {
        var schemaVersion: Int
        var profiles: [TranslationProfile]
    }

    private let fileURL: URL
    private let cache: OSAllocatedUnfairLock<[TranslationProfile]>

    public init(fileURL: URL = AppPaths.translationProfiles) {
        self.fileURL = fileURL
        var profiles: [TranslationProfile] = []
        if let data = try? Data(contentsOf: fileURL),
           let contents = try? JSONCoding.decoder().decode(FileContents.self, from: data) {
            profiles = contents.profiles
        }
        if profiles.isEmpty {
            // 首次启动：内置一个 Google 配置（R8.1 默认使用 Google）
            profiles = [.defaultGoogle()]
        }
        cache = OSAllocatedUnfairLock(initialState: profiles)
    }

    public var profiles: [TranslationProfile] {
        cache.withLock { $0 }
    }

    public func profile(id: UUID) -> TranslationProfile? {
        profiles.first { $0.id == id }
    }

    /// 解析实际使用的配置：指定 ID → 全局默认 ID → 第一个配置。
    public func resolve(_ id: UUID?, defaultID: UUID?) -> TranslationProfile? {
        let all = profiles
        if let id, let match = all.first(where: { $0.id == id }) { return match }
        if let defaultID, let match = all.first(where: { $0.id == defaultID }) { return match }
        return all.first
    }

    /// 新增或更新配置。
    public func upsert(_ profile: TranslationProfile) throws {
        try mutate { profiles in
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
        }
    }

    /// 删除配置，同时删除它在钥匙串中的 Key（Google 的 Key 全局共用，不删除）。
    public func remove(id: UUID, secrets: any SecretStore) throws {
        guard let profile = profile(id: id) else { return }
        try mutate { profiles in profiles.removeAll { $0.id == id } }
        if !profile.isGoogle {
            try? secrets.setSecret(nil, for: profile.secretAccount)
        }
    }

    private func mutate(_ change: (inout [TranslationProfile]) -> Void) throws {
        var copy = profiles
        change(&copy)
        let data = try JSONCoding.encoder().encode(FileContents(schemaVersion: 1, profiles: copy))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        let updated = copy
        cache.withLock { $0 = updated }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
