import AppKit
import Observation
import SwiftUI
import TransPeekKit

/// 编辑页的状态：草稿、保存、还原、测试（S7）。
@MainActor
@Observable
final class ServiceEditorModel {
    var draft: ProfileDraft
    var revealsKey = false
    private(set) var saveError: String?
    /// 编辑开始时钥匙串中已有的 Key（用于“已保存在钥匙串”的提示）。
    private(set) var savedKey: String

    @ObservationIgnored let context: SettingsContext

    init(route: ServiceRoute, context: SettingsContext) {
        self.context = context
        switch route {
        case let .existing(id):
            let profile = context.services.profiles.profile(id: id) ?? .defaultGoogle()
            let key = context.services.secrets.secret(for: profile.secretAccount) ?? ""
            draft = ProfileDraft(profile: profile, apiKey: key, isNew: false)
            savedKey = key
        case let .new(profile, apiKey):
            let key = profile.isGoogle ? (context.services.secrets.secret(for: SecretAccount.google) ?? "") : apiKey
            draft = ProfileDraft(profile: profile, apiKey: key, isNew: true)
            savedKey = profile.isGoogle ? key : ""
        }
    }

    var preset: LLMPreset? {
        draft.isGoogle ? nil : context.services.presets.presetOrCustom(id: draft.presetID)
    }

    var protocolLabel: String {
        draft.isGoogle ? "Google Cloud Translation v2" : "\(draft.protocolKind.displayName)接口"
    }

    var isDefault: Bool { context.defaultProfileID == draft.id && !draft.isNew }

    var canDelete: Bool { !draft.isNew && context.profiles.profiles.count > 1 }

    var testState: ConnectionTestState { context.statuses.results[draft.id] ?? .idle }

    var keyIsSavedAndUnchanged: Bool { !savedKey.isEmpty && draft.apiKey == savedKey }

    var baseURLDiffersFromPreset: Bool {
        guard let preset, !preset.baseURL.isEmpty else { return false }
        return draft.baseURL != preset.baseURL
    }

    /// 保存。成功返回 `true`（S7.7）。
    @discardableResult
    func save() -> Bool {
        guard let profile = draft.makeProfile() else { return false }
        do {
            try context.services.secrets.setSecret(draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: profile.secretAccount)
            try context.services.profiles.upsert(profile)
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
            return false
        }
        let wasNew = draft.isNew
        draft.markSaved()
        savedKey = draft.apiKey
        saveError = nil
        Task { await context.services.registry.invalidate() }
        context.setup.refresh()
        if wasNew { context.router.replaceServiceRoute(.existing(profile.id)) }
        return true
    }

    func revert() {
        draft.revert()
    }

    func test() {
        guard let profile = draft.makeProfile() else { return }
        let key = draft.apiKey
        Task { await context.statuses.run(profile, apiKey: key, services: context.services) }
    }

    func makeDefault() {
        context.settings.settings.defaultProfileID = draft.id
    }

    func delete() {
        do {
            try context.services.profiles.remove(id: draft.id, secrets: context.services.secrets)
            if context.settings.settings.defaultProfileID == draft.id {
                context.settings.settings.defaultProfileID = context.services.profiles.profiles.first?.id
            }
            context.statuses.clear(draft.id)
            Task { await context.services.registry.invalidate() }
            draft.markSaved() // 已删除，离开时不再询问
            context.router.backToServices()
        } catch {
            saveError = "删除失败：\(error.localizedDescription)"
        }
    }
}

/// 编辑翻译服务（S7）。
struct ServiceEditorPage: View {
    @State private var model: ServiceEditorModel
    @State private var guardToken: UUID?
    @State private var showsDeleteConfirmation = false
    @State private var advancedExpanded = false

    init(context: SettingsContext, route: ServiceRoute) {
        _model = State(initialValue: ServiceEditorModel(route: route, context: context))
    }

    private var router: SettingsRouter { model.context.router }
    private var issues: [ProfileDraft.Field: String] { model.draft.issues }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    connectionCard
                    if let note = model.preset?.note {
                        Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                    }
                    testCard
                    if !model.draft.isGoogle {
                        advancedCard
                        fallbackCard
                    }
                    if let error = model.saveError {
                        Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            bottomBar
        }
        .onAppear {
            guardToken = router.registerEditor(
                hasUnsavedChanges: { [model] in model.draft.isDirty },
                save: { [model] in model.save() }
            )
        }
        .onDisappear {
            if let guardToken { router.unregisterEditor(guardToken) }
        }
        .onExitCommand { router.backToServices() }
        .confirmationDialog("删除“\(model.draft.name)”？", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) { model.delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.draft.isGoogle ? "Google API Key 由所有 Google 配置共用，不会被删除。" : "该配置的 API Key 会一起从钥匙串中删除。")
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                router.backToServices()
            } label: {
                Label("翻译服务", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            HStack(spacing: 12) {
                ProviderIcon(presetID: model.draft.isGoogle ? "google" : model.draft.presetID, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.draft.name.isEmpty ? "未命名" : model.draft.name).font(.title2.bold())
                        if model.isDefault { OutlineTag(text: "默认") }
                    }
                    Text(model.draft.isNew ? "新配置 · \(model.protocolLabel)" : model.protocolLabel).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.draft.isDirty {
                    StatusLabel(text: model.draft.isNew ? "尚未保存" : "有未保存的修改", tone: .warning)
                }
            }
        }
    }

    // MARK: - 连接

    private var connectionCard: some View {
        SettingsCard(title: "连接") {
            SettingsRow(title: "名称", error: issues[.name]) {
                TextField("名称", text: $model.draft.name).labelsHidden().frame(width: 320)
            }
            if !model.draft.isGoogle {
                if model.draft.presetID == LLMPreset.customID {
                    SettingsDivider()
                    SettingsRow(title: "接口协议") {
                        Picker("接口协议", selection: $model.draft.protocolKind) {
                            ForEach(LLMProtocol.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 320)
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Base URL", detail: "只有本机和局域网地址可以使用 http://", error: issues[.baseURL]) {
                    HStack(spacing: 6) {
                        TextField("https://api.example.com/v1", text: $model.draft.baseURL)
                            .labelsHidden().font(.system(.body, design: .monospaced))
                        if model.baseURLDiffersFromPreset, let preset = model.preset {
                            Button("恢复默认") { model.draft.baseURL = preset.baseURL }.buttonStyle(.link).font(.caption)
                        }
                    }
                    .frame(width: 320)
                }
            }
            SettingsDivider()
            SettingsRow(title: "API Key", detail: keyDetail) {
                HStack(spacing: 6) {
                    Group {
                        if model.revealsKey {
                            TextField(keyPlaceholder, text: $model.draft.apiKey).font(.system(.body, design: .monospaced))
                        } else {
                            SecureField(keyPlaceholder, text: $model.draft.apiKey)
                        }
                    }
                    .labelsHidden()
                    Button {
                        model.revealsKey.toggle()
                    } label: {
                        Image(systemName: model.revealsKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(model.revealsKey ? "隐藏" : "显示")
                    .accessibilityLabel(model.revealsKey ? "隐藏 API Key" : "显示 API Key")
                }
                .frame(width: 320)
            }
            if !model.draft.isGoogle {
                SettingsDivider()
                SettingsRow(title: "模型 ID", detail: "填写服务商文档中的模型 ID。游戏聊天建议选非推理的快速模型。", error: issues[.model]) {
                    HStack(spacing: 6) {
                        TextField("例如 deepseek-flash", text: $model.draft.model)
                            .labelsHidden().font(.system(.body, design: .monospaced))
                        if let url = model.preset?.modelsDocURL {
                            Button("查看模型列表") { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.caption)
                        }
                    }
                    .frame(width: 320)
                }
            }
        }
    }

    private var keyPlaceholder: String {
        model.preset?.requiresAPIKey == false ? "可选" : "必填"
    }

    private var keyDetail: String {
        if model.keyIsSavedAndUnchanged {
            return "已保存在钥匙串，末 4 位 \(String(model.draft.apiKey.suffix(4)))"
        }
        if model.draft.isGoogle {
            return "所有 Google 配置共用同一个 Key。"
        }
        return model.preset?.requiresAPIKey == false ? "本地服务通常不需要 Key。" : "保存后存入 macOS 钥匙串。"
    }

    // MARK: - 测试连接（S7.5）

    private var testCard: some View {
        SettingsCard(title: "测试连接") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("用示例文本发一次真实请求，使用当前填写的值，不需要先保存。").font(.caption).foregroundStyle(.secondary)
                    testResult
                }
                Spacer(minLength: 12)
                Button(model.testState == .idle ? "测试" : "再测一次") { model.test() }
                    .disabled(model.testState == .running || model.draft.makeProfile() == nil)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch model.testState {
        case .idle:
            Text("\(ConnectionTest.sampleText) → ？").font(.callout).foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在测试…").font(.callout) }
        case let .success(translation, milliseconds):
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ConnectionTest.sampleText) → \(translation)").font(.callout).textSelection(.enabled)
                StatusLabel(text: "成功 · \(milliseconds) ms", tone: .ok)
            }
        case let .failure(message):
            VStack(alignment: .leading, spacing: 2) {
                StatusLabel(text: "失败", tone: .problem)
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 高级（S7.6）

    private var advancedCard: some View {
        SettingsCard {
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsDivider().padding(.top, 8)
                    SettingsRow(title: "温度", detail: "越低译文越稳定。翻译建议 0.1–0.3。") {
                        HStack {
                            Slider(value: $model.draft.temperature.rounded(to: 0.1), in: 0...1).frame(width: 180).accessibilityLabel("温度")
                            Text(model.draft.temperature, format: .number.precision(.fractionLength(1))).monospacedDigit().frame(width: 28)
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "上下文条数", detail: "附带该区域最近几条已翻译的消息，让译文前后连贯。0 表示不附带。") {
                        Stepper(value: $model.draft.contextCount, in: LLMConfig.contextCountRange) {
                            Text("\(model.draft.contextCount) 条").monospacedDigit()
                        }
                    }
                    SettingsDivider()
                    promptEditor
                    SettingsDivider()
                    extraBodyEditor
                }
            } label: {
                HStack {
                    Text("高级").font(.body.weight(.medium))
                    if !advancedExpanded {
                        Text(advancedSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { advancedExpanded.toggle() } }
            }
            .padding(14)
        }
    }

    private var advancedSummary: String {
        let prompt = model.draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "内置提示词" : "自定义提示词"
        let extra = model.draft.extraBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "无额外参数" : "有额外参数"
        let temperature = String(format: "%.1f", model.draft.temperature)
        return "温度 \(temperature) · 上下文 \(model.draft.contextCount) 条 · \(prompt) · \(extra)"
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("提示词")
                Spacer()
                Button("插入内置模板") { model.draft.systemPrompt = PromptBuilder.defaultSystemPrompt }
                    .buttonStyle(.link).font(.caption)
                if !model.draft.systemPrompt.isEmpty {
                    Button("清空（使用内置）") { model.draft.systemPrompt = "" }.buttonStyle(.link).font(.caption)
                }
            }
            TextEditor(text: $model.draft.systemPrompt)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 100)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    if model.draft.systemPrompt.isEmpty {
                        Text("留空使用内置的游戏/软件界面翻译提示词").font(.caption).foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("提示词")
            Text("只需要写翻译规则。返回 JSON 的格式说明会自动附加在提示词后面。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("插入变量").font(.caption).foregroundStyle(.secondary)
                ForEach(PromptBuilder.variables, id: \.self) { variable in
                    Button(variable) { model.draft.systemPrompt += variable }
                        .font(.system(.caption, design: .monospaced))
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var extraBodyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("额外请求参数（JSON）")
            TextEditor(text: $model.draft.extraBody)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: issues[.extraBody] == nil ? .separatorColor : .systemRed)))
                .accessibilityLabel("额外请求参数")
            if let error = issues[.extraBody] {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            } else {
                Text(#"浅合并到请求体，用户参数优先；值为 null 时删除该参数。例如 {"max_tokens": null, "max_completion_tokens": 1024}"#)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 回退

    private var fallbackCard: some View {
        SettingsCard {
            SettingsRow(
                title: "失败时回退到 Google 翻译",
                detail: model.context.services.secrets.secret(for: SecretAccount.google) == nil && model.draft.fallbackToGoogle
                    ? "还没有配置 Google API Key，回退不会生效。"
                    : "LLM 请求最终失败时改用 Google 翻译，面板中标注“已回退”。"
            ) {
                Toggle("失败时回退到 Google 翻译", isOn: $model.draft.fallbackToGoogle).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    // MARK: - 底部操作栏（S7.7）

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if model.canDelete {
                Button("删除此服务", role: .destructive) { showsDeleteConfirmation = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
            Spacer()
            if !model.draft.isNew && !model.isDefault {
                Button("设为默认") { model.makeDefault() }
            }
            if !model.draft.isNew {
                Button("还原") { model.revert() }.disabled(!model.draft.isDirty)
            }
            Button("保存") { model.save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.draft.canSave)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }
}
