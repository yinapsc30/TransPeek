#if DEBUG
import AppKit
import SwiftUI
import TransPeekKit

/// 开发工具（仅 Debug 构建）：把设置窗口的各个页面离屏渲染成 PNG，用于检查布局。
///
///     TransPeek.app/Contents/MacOS/TransPeek --settings-snapshots /tmp/out
///
/// 另外模拟一次侧边栏点击（向“识别”所在的位置发送鼠标事件），保存为 click-test.png，
/// 用于确认侧边栏可以点击。
@MainActor
enum DebugSnapshots {
    static var isRequested: Bool { CommandLine.arguments.contains("--settings-snapshots") }

    static func runIfRequested(context: SettingsContext) -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--settings-snapshots"), index + 1 < arguments.count else { return false }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var targets: [(String, () -> Void)] = SettingsPane.allCases.map { pane in
            (pane.rawValue, { context.router.select(pane) })
        }
        if let first = context.profiles.profiles.first {
            targets.append(("service-editor", { context.router.openService(.existing(first.id)) }))
        }
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 900, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsRootView(context: context))
        window.orderFront(nil)

        Task { @MainActor in
            for (name, select) in targets {
                select()
                try? await Task.sleep(for: .milliseconds(600))
                save(window, to: directory.appendingPathComponent("\(name).png"))
            }
            // 模拟点击侧边栏：先选中“关于”，再点击第 3 行“识别”（行高 28 + 间距 2，顶部内边距 12）
            context.router.select(.about)
            try? await Task.sleep(for: .milliseconds(300))
            click(window, at: CGPoint(x: 80, y: 12 + 30 * 2 + 14))
            try? await Task.sleep(for: .milliseconds(600))
            save(window, to: directory.appendingPathComponent("click-test.png"))
            print("click-test: pane=\(context.router.pane.rawValue)")
            await panelSnapshots(to: directory)
            NSApp.terminate(nil)
        }
        return true
    }

    /// 面板的几种状态（panel-groups、panel-redesign）：两种样式的静止、悬停、Aa 工具条、折叠、左右排列、单栏、精简显示；
    /// 并模拟拖动分隔条。离屏渲染拍不到毛玻璃，只能看到底色。
    private static func panelSnapshots(to directory: URL) async {
        let chat = Region(name: "聊天频道", rect: CGRect(x: 0, y: 0, width: 1, height: 0.5), mode: .chat, targetLanguage: .simplifiedChinese)
        let dialog = Region(name: "NPC 对话", rect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), mode: .dialog, targetLanguage: .simplifiedChinese)
        let sections = [SectionController(region: chat, historyLimit: 100), SectionController(region: dialog, historyLimit: 100)]
        sections[0].apply(.append([
            Entry(regionID: chat.id, original: "Kael 21:04", translation: .metadata),
            Entry(regionID: chat.id, original: "Anyone selling iron ore?", translation: .done("有人卖铁矿石吗？")),
            Entry(regionID: chat.id, original: "Mira — Today at 21:05", translation: .metadata),
            Entry(regionID: chat.id, original: "WTB healing potions x20", translation: .done("求购治疗药水 x20", fallback: true)),
            Entry(regionID: chat.id, original: "brb", translation: .failed("timeout")),
            Entry(regionID: chat.id, original: "Dorn 21:05", translation: .metadata),
            Entry(regionID: chat.id, original: "LFG dungeon, need tank", translation: .done("组队下副本，缺坦克")),
        ]))
        sections[1].apply(.dialog(Entry(regionID: dialog.id, original: "Welcome, traveler.", translation: .done("欢迎你，旅行者。"), kind: .dialogSnapshot)))
        sections[1].apply(.dialog(Entry(
            regionID: dialog.id,
            original: "The bridge to the north has collapsed. You'll need another way across.",
            translation: .done("北边的桥塌了，你得另找办法过河。"),
            kind: .dialogSnapshot
        )))
        let target = CGRect(x: -30000, y: 100, width: 1200, height: 800)
        var group = PanelGroup(
            placement: .docked(edge: .right, thickness: 320),
            opacity: 0.85,
            sections: [PanelSection(regionID: chat.id, weight: 3), PanelSection(regionID: dialog.id, weight: 2)]
        )
        let window = PanelWindowController(group: group, targetFrame: target)
        func shot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(400))
            save(window.panel, to: directory.appendingPathComponent("panel-\(name).png"))
        }
        func place(_ placement: PanelPlacement, dock: DockLayout?, sections active: [SectionController], regionIDs: [UUID]) {
            group = window.group
            group.placement = placement
            group.sections = regionIDs.map { id in window.group.sections.first { $0.regionID == id } ?? PanelSection(regionID: id, weight: 2) }
            window.setGroup(group, sections: active)
            window.applyLayout(dock)
        }
        let rightDock = DockLayout(frame: CGRect(x: -28800, y: 100, width: 320, height: 560), placement: .outside, edge: .right)

        // HUD：上下两栏
        place(.docked(edge: .right, thickness: 320), dock: rightDock, sections: sections, regionIDs: [chat.id, dialog.id])
        await shot("hud")
        window.setHoveringForSnapshot(true)
        sections[0].toggleTextTools()
        sections[1].toggleDialogHistory()
        await shot("hud-hover")
        sections[0].hideTextTools()
        sections[1].toggleDialogHistory()

        // 分隔条拖动：向下 60pt
        let size = window.panel.frame.size
        let divider = window.sectionFrames(in: size).dividers.first ?? .zero
        let hit = window.divider(at: CGPoint(x: divider.midX, y: divider.midY), in: size)
        window.beginDividerDrag(0, size: size)
        window.dragDivider(by: 60)
        window.endDividerDrag()
        let weights = window.group.sections.map { String(format: "%.2f", $0.weight) }.joined(separator: ",")
        print("divider-test: hit=\(hit.map(String.init) ?? "nil") weights=\(weights)")

        // 折叠对话栏，折叠期间来一段新对话
        window.setHoveringForSnapshot(false)
        window.toggleSectionCollapsed(sections[1])
        sections[1].apply(.dialog(Entry(regionID: dialog.id, original: "Hello", translation: .done("你好"), kind: .dialogSnapshot)))
        print("collapse-test: collapsed=\(sections[1].isCollapsed) unread=\(sections[1].collapsedUnread) canCollapseOther=\(window.canCollapse(chat.id))")
        await shot("hud-collapsed")
        window.toggleSectionCollapsed(sections[1])

        // HUD：贴底边，左右排列
        place(.docked(edge: .bottom, thickness: 180), dock: DockLayout(frame: CGRect(x: -30000, y: 900, width: 900, height: 180), placement: .outside, edge: .bottom),
              sections: sections, regionIDs: [chat.id, dialog.id])
        window.setHoveringForSnapshot(true)
        await shot("hud-horizontal")
        window.setHoveringForSnapshot(false)

        // 字幕：悬浮两栏
        place(.floating(offset: .zero, size: CGSize(width: 340, height: 480)), dock: nil, sections: sections, regionIDs: [chat.id, dialog.id])
        await shot("subtitle")
        window.setHoveringForSnapshot(true)
        await shot("subtitle-hover")
        window.setHoveringForSnapshot(false)

        // 单栏
        place(.docked(edge: .right, thickness: 320), dock: DockLayout(frame: CGRect(x: -28800, y: 100, width: 320, height: 300), placement: .outside, edge: .right),
              sections: [sections[0]], regionIDs: [chat.id])
        window.setHoveringForSnapshot(true)
        await shot("hud-single")
        window.setHoveringForSnapshot(false)
        place(.floating(offset: .zero, size: CGSize(width: 360, height: 150)), dock: nil, sections: [sections[1]], regionIDs: [dialog.id])
        await shot("subtitle-single")
        place(.floating(offset: .zero, size: CGSize(width: 340, height: 70)), dock: nil, sections: [sections[0]], regionIDs: [chat.id])
        await shot("subtitle-compact")
        window.tearDown()
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `point` 为内容区域中的位置，原点左上。
    private static func click(_ window: NSWindow, at point: CGPoint) {
        guard let contentHeight = window.contentView?.bounds.height else { return }
        let location = CGPoint(x: point.x, y: contentHeight - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) {
                window.sendEvent(event)
            }
        }
    }
}
#endif
