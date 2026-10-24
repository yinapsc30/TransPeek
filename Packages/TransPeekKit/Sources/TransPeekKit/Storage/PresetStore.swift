import Foundation
import OSLog

/// 读取预设的结果。
public struct PresetLoadResult: Sendable {
    public let preset: AppPreset
    /// 预设文件损坏，已备份为 `.corrupt` 并返回空预设（design.md「错误处理」）。
    public let recoveredFromCorruption: Bool
}

/// 按 Bundle ID 读写 `presets/<bundleID>.json`（R4.7）。
public actor PresetStore {
    private let directory: URL
    private let debounce: Duration
    private let sleeper: any Sleeper
    private let logger = Logger(subsystem: AppIdentity.subsystem, category: "preset")

    private var pending: [String: AppPreset] = [:]
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    /// 实际写盘次数，供测试检查防抖效果。
    private(set) var writeCount = 0

    public init(
        directory: URL = AppPaths.presets,
        debounce: Duration = .milliseconds(500),
        sleeper: any Sleeper = TaskSleeper()
    ) {
        self.directory = directory
        self.debounce = debounce
        self.sleeper = sleeper
    }

    public func fileURL(for bundleID: String) -> URL {
        // Bundle ID 正常只含字母、数字、点和连字符，其余字符替换掉，避免路径穿越
        let safe = String(bundleID.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).json")
    }

    public func load(bundleID: String) -> PresetLoadResult {
        if let pendingPreset = pending[bundleID] {
            return PresetLoadResult(preset: pendingPreset, recoveredFromCorruption: false)
        }
        let url = fileURL(for: bundleID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PresetLoadResult(preset: .empty(bundleID: bundleID), recoveredFromCorruption: false)
        }
        do {
            let data = try Data(contentsOf: url)
            let preset = try JSONCoding.decoder().decode(AppPreset.self, from: data)
            return PresetLoadResult(preset: preset, recoveredFromCorruption: false)
        } catch {
            logger.error("Preset file is corrupt, backing up: \(url.lastPathComponent, privacy: .public)")
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return PresetLoadResult(preset: .empty(bundleID: bundleID), recoveredFromCorruption: true)
        }
    }

    /// 任意应用的预设中是否至少有一个区域（S2.3）。
    public func hasAnyRegion() -> Bool {
        if pending.values.contains(where: { !$0.regions.isEmpty }) { return true }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        let decoder = JSONCoding.decoder()
        return files.contains { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let preset = try? decoder.decode(AppPreset.self, from: data)
            else { return false }
            return !preset.regions.isEmpty
        }
    }

    /// 立即写入。
    public func save(_ preset: AppPreset) throws {
        pendingTasks.removeValue(forKey: preset.bundleID)?.cancel()
        pending.removeValue(forKey: preset.bundleID)
        try write(preset)
    }

    /// 防抖写入：同一应用在防抖时间内的多次修改只写一次。
    public func scheduleSave(_ preset: AppPreset) {
        let bundleID = preset.bundleID
        pending[bundleID] = preset
        pendingTasks[bundleID]?.cancel()
        let sleeper = self.sleeper
        let debounce = self.debounce
        pendingTasks[bundleID] = Task { [weak self] in
            do {
                try await sleeper.sleep(for: debounce)
            } catch {
                return // 被新的修改取消
            }
            await self?.writePending(bundleID: bundleID)
        }
    }

    /// 立即写入所有待写入的预设（应用退出时调用）。
    public func flush() {
        for bundleID in Array(pending.keys) {
            pendingTasks.removeValue(forKey: bundleID)?.cancel()
            writePending(bundleID: bundleID)
        }
    }

    private func writePending(bundleID: String) {
        pendingTasks.removeValue(forKey: bundleID)
        guard let preset = pending.removeValue(forKey: bundleID) else { return }
        do {
            try write(preset)
        } catch {
            logger.error("Failed to save preset: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write(_ preset: AppPreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stamped = preset
        stamped.schemaVersion = AppPreset.currentSchemaVersion
        let data = try JSONCoding.encoder().encode(stamped)
        try data.write(to: fileURL(for: preset.bundleID), options: .atomic)
        writeCount += 1
    }
}
