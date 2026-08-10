import SwiftUI

// ==========================================
// UsageBar - macOS 菜单栏 Token 用量查看器
// 菜单栏直接显示最高用量百分比，点击弹出详情
// ==========================================

@main
struct UsageBarApp: App {
    @State private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePanelView(model: model)
        } label: {
            Text(model.menuBarText)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(model.menuBarColor)
                .padding(.horizontal, 2)
        }
        .menuBarExtraStyle(.window)
    }
}
