import SwiftUI
import TransPeekKit

/// 区域管理：重命名、修改模式/语言/翻译配置/忽略规则、暂停、删除、重新框选（R4.5、R4.6、R4.8）。
struct RegionManagerView: View {
    let coordinator: SessionCoordinator
    let profiles: TranslationProfileStore

    @State private var selection: UUID?
    @State private var draft: Region?
    /// 草稿中的所在面板，保存时生效（panel-groups G4.6）。
    @State private var draftDestination: PanelDestination = .newPanel

    var body: some View {
        Group {
            if let target = coordinator.target {
                HSplitView {
                    regionList(target: target)
                        .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)
                    editor
                        .frame(minWidth: 380)
                }
            } else {
                ContentUnavailableView(
                    "还没有目标窗口",
                    systemImage: "macwindow",
                    description: Text("在菜单栏中选择目标窗口，或切换到目标应用后按 ⌃⌥T 框选区域。")
                )
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        .onChange(of: selection) { loadDraft() }
        .onChange(of: coordinator.regions) {
            if let selection, !coordinator.regions.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
            // 面板中的修改（位置、字号等）同步到草稿，避免保存时覆盖
            if let current = coordinator.regions.first(where: { $0.id == selection }), var draft {
                draft.panel = current.panel
                draft.isPaused = current.isPaused
                self.draft = draft
            }
        }
        .onChange(of: currentDestination) {
            // 在面板菜单中移动了区域，同步到草稿
            draftDestination = currentDestination
        }
    }

    private var currentDestination: PanelDestination {
        guard let selection, let groupID = coordinator.groupID(containing: selection) else { return .newPanel }
        return .group(groupID)
    }

    private func regionList(target: TrackedWindow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target.displayTitle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .padding(8)
            List(selection: $selection) {
                ForEach(coordinator.regions) { region in
                    HStack {
                        Image(systemName: region.isPaused ? "pause.circle" : "text.viewfinder")
                            .foregroundStyle(region.isPaused ? Color.secondary : Color.accentColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(region.name)
                            Text(region.isPaused ? "\(region.mode.displayName) · 已暂停" : region.mode.displayName)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(region.id)
                }
            }
            HStack {
                Button {
                    Task { await coordinator.beginRegionSelection() }
                } label: {
                    Label("框选新区域", systemImage: "plus")
                }
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let draftBinding = Binding($draft) {
            VStack(spacing: 0) {
                RegionForm(region: draftBinding, profiles: profiles.profiles) {
                    PanelDestinationPicker(
                        title: "面板",
                        selection: $draftDestination,
                        choices: coordinator.panelChoices(),
                        currentGroupID: coordinator.groupID(containing: draftBinding.wrappedValue.id)
                    )
                }
                Divider()
                HStack {
                    Button(draftBinding.wrappedValue.isPaused ? "恢复" : "暂停") {
                        coordinator.setPaused(draftBinding.wrappedValue.id, !draftBinding.wrappedValue.isPaused)
                        draft?.isPaused.toggle()
                    }
                    Button("重新框选") {
                        let id = draftBinding.wrappedValue.id
                        Task { await coordinator.beginRegionSelection(reselecting: id) }
                    }
                    Button("删除", role: .destructive) {
                        coordinator.deleteRegion(draftBinding.wrappedValue.id)
                        selection = nil
                    }
                    Spacer()
                    Button("保存") {
                        guard let draft else { return }
                        if draft != coordinator.regions.first(where: { $0.id == draft.id }) {
                            coordinator.updateRegion(draft)
                        }
                        if draftDestination != currentDestination {
                            coordinator.moveRegion(draft.id, to: draftDestination)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled((draft == coordinator.regions.first { $0.id == selection } && draftDestination == currentDestination)
                              || draftBinding.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
        } else {
            Text("选择一个区域进行编辑").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadDraft() {
        draft = coordinator.regions.first { $0.id == selection }
        draftDestination = currentDestination
    }
}
