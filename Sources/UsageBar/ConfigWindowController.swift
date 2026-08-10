import AppKit
import SwiftUI

// ==========================================
// 配置窗口：独立 NSPanel，不随菜单栏窗口关闭
// （MenuBarExtra + sheet 点击外部会连带消失，改用独立窗口）
// ==========================================

@MainActor
final class ConfigWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var model: UsageModel?

    init(model: UsageModel) {
        self.model = model
        super.init()
    }

    func show() {
        Self.debugLog("ConfigWindowController.show 调用")
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let model else { return }
        let view = ConfigView(model: model) { [weak self] in self?.close() }
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenCode Go 配置"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.hidesOnDeactivate = false   // 点击外部/app 失活时不隐藏
        panel.isFloatingPanel = true      // 浮动面板：失活后仍显示在最上层
        panel.contentViewController = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        Self.debugLog("配置窗口已创建并显示")
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }

    // MARK: - 日志

    static func debugLog(_ msg: String) {
        guard ProcessInfo.processInfo.environment["USAGEBAR_DEBUG"] == "1" else { return }
        let line = "[配置] \(msg)\n"
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/UsageBar.log")
        if let data = line.data(using: .utf8),
           let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}
