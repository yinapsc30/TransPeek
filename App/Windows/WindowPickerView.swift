import AppKit
import SwiftUI

/// 选择目标窗口（R3.1）。
struct WindowPickerView: View {
    let onSelect: (TrackedWindow) -> Void
    let onCancel: () -> Void

    @State private var windows: [TrackedWindow] = []
    @State private var thumbnails: [CGWindowID: NSImage] = [:]
    @State private var selection: CGWindowID?
    @State private var errorMessage: String?
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isLoading {
                    ProgressView("正在读取窗口列表…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView("无法读取窗口列表", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if windows.isEmpty {
                    ContentUnavailableView("没有可选择的窗口", systemImage: "macwindow")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(windows) { window in
                                WindowCard(window: window, thumbnail: thumbnails[window.windowID], isSelected: selection == window.windowID)
                                    .onTapGesture { selection = window.windowID }
                                    .onTapGesture(count: 2) { onSelect(window) }
                                    .accessibilityAddTraits(selection == window.windowID ? [.isButton, .isSelected] : .isButton)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            Divider()
            HStack {
                Button("刷新") { Task { await load() } }
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("选择") {
                    if let window = windows.first(where: { $0.windowID == selection }) { onSelect(window) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            windows = try await WindowCatalog.candidates()
        } catch {
            errorMessage = "请确认已授予屏幕录制权限。（\(error.localizedDescription)）"
        }
        isLoading = false
        for window in windows where thumbnails[window.windowID] == nil {
            if let image = await WindowCatalog.thumbnail(window.windowID) {
                thumbnails[window.windowID] = NSImage(cgImage: image, size: .zero)
            }
        }
    }
}

private struct WindowCard: View {
    let window: TrackedWindow
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: "macwindow").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(height: 120)
            HStack(spacing: 6) {
                if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                }
                Text(window.appName).font(.headline).lineLimit(1)
            }
            Text(window.title.isEmpty ? "（无标题）" : window.title)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.appName)，\(window.title)")
    }
}
