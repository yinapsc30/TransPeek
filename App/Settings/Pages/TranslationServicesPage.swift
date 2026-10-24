import SwiftUI
import TransPeekKit

/// 翻译服务列表（S6）。
struct TranslationServicesPage: View {
    let context: SettingsContext

    @State private var showsAddSheet = false
    @State private var pendingDelete: TranslationProfile?
    @State private var errorMessage: String?

    var body: some View {
        SettingsPage(title: SettingsPane.services.title, subtitle: SettingsPane.services.subtitle) {
            HStack {
                Spacer()
                Button {
                    showsAddSheet = true
                } label: {
                    Label("添加服务", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, -8)

            VStack(spacing: 10) {
                ForEach(context.profiles.profiles) { profile in
                    ServiceCard(
                        profile: profile,
                        isDefault: profile.id == context.defaultProfileID,
                        summary: context.summary(of: profile),
                        status: context.status(of: profile),
                        menu: { menuItems(for: profile) }
                    ) {
                        context.router.openService(.existing(profile.id))
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("怎么选").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("聊天频道刷新快：用 Google 翻译或非推理的快速模型。剧情对话想要更自然的译文：用 LLM。不想把文字发到网上：用 Ollama 或 LM Studio 本地模型。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
        }
        .sheet(isPresented: $showsAddSheet) {
            AddServiceSheet(presets: context.services.presets) { profile in
                showsAddSheet = false
                context.router.openService(.new(profile, apiKey: ""))
            } onCancel: {
                showsAddSheet = false
            }
        }
        .confirmationDialog(
            "删除“\(pendingDelete?.name ?? "")”？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { profile in
            Button("删除", role: .destructive) { delete(profile) }
            Button("取消", role: .cancel) {}
        } message: { profile in
            Text(profile.isGoogle ? "Google API Key 由所有 Google 配置共用，不会被删除。" : "该配置的 API Key 会一起从钥匙串中删除。使用这个配置的区域会改用默认配置。")
        }
    }

    @ViewBuilder
    private func menuItems(for profile: TranslationProfile) -> some View {
        Button("编辑…") { context.router.openService(.existing(profile.id)) }
        Button("设为默认") { context.settings.settings.defaultProfileID = profile.id }
            .disabled(profile.id == context.defaultProfileID)
        Button("测试连接") {
            let key = context.services.secrets.secret(for: profile.secretAccount) ?? ""
            Task { await context.statuses.run(profile, apiKey: key, services: context.services) }
        }
        Button("复制为新配置") { duplicate(profile) }
        Divider()
        Button("删除…", role: .destructive) { pendingDelete = profile }
            .disabled(context.profiles.profiles.count <= 1)
    }

    private func duplicate(_ profile: TranslationProfile) {
        let copy = TranslationProfile(name: "\(profile.name) 副本", kind: profile.kind)
        let key = context.services.secrets.secret(for: profile.secretAccount) ?? ""
        context.router.openService(.new(copy, apiKey: key))
    }

    private func delete(_ profile: TranslationProfile) {
        guard context.profiles.profiles.count > 1 else { return }
        do {
            try context.services.profiles.remove(id: profile.id, secrets: context.services.secrets)
            if context.settings.settings.defaultProfileID == profile.id {
                context.settings.settings.defaultProfileID = context.services.profiles.profiles.first?.id
            }
            context.statuses.clear(profile.id)
            Task { await context.services.registry.invalidate() }
            errorMessage = nil
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}

/// 一张服务卡片：图标、名称、摘要、状态、“默认”标记（S6.1、S6.3）。
private struct ServiceCard<Menu: View>: View {
    let profile: TranslationProfile
    let isDefault: Bool
    let summary: String
    let status: ServiceStatus
    @ViewBuilder let menu: () -> Menu
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            ProviderIcon(presetID: profile.iconID)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(profile.name).font(.body.weight(.semibold))
                    if isDefault { OutlineTag(text: "默认") }
                }
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            StatusLabel(status).frame(maxWidth: 220, alignment: .trailing)
            SwiftUI.Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多操作")
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: isHovering ? .unemphasizedSelectedContentBackgroundColor : .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu { menu() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(profile.name)\(isDefault ? "，默认" : "")，\(status.label)")
        .accessibilityAction(named: "编辑", open)
    }
}

/// 选择服务商（S6.5）。
private struct AddServiceSheet: View {
    let presets: LLMPresetCatalog
    let onSelect: (TranslationProfile) -> Void
    let onCancel: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("添加翻译服务").font(.title3.bold())
                Text("选择服务商，下一步填写 API Key 和模型。").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    tile(id: "google", name: "Google 翻译", detail: "机器翻译，速度快") {
                        onSelect(TranslationProfile(name: "Google 翻译", kind: .google))
                    }
                    ForEach(presets.presets) { preset in
                        tile(id: preset.id, name: preset.name, detail: detail(for: preset)) {
                            if let config = presets.makeConfig(presetID: preset.id) {
                                onSelect(TranslationProfile(name: preset.name, kind: .llm(config)))
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    private func detail(for preset: LLMPreset) -> String {
        if preset.id == LLMPreset.customID { return "任意 OpenAI 兼容接口" }
        if !preset.requiresAPIKey { return "本地运行，不需要 Key" }
        return URL(string: preset.baseURL)?.host ?? preset.baseURL
    }

    private func tile(id: String, name: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProviderIcon(presetID: id, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name)，\(detail)")
    }
}
