import SwiftUI

// ==========================================
// 配置面板：浏览器登录 + 刷新频率设置
// 显示在独立窗口（ConfigWindowController）中
// ==========================================

struct ConfigView: View {
    let model: UsageModel
    var onClose: () -> Void = {}

    @State private var refreshIntervalSec = 300
    @State private var menuBarDisplay = "auto"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenCode Go 配置")
                .font(.headline)

            Text("点击登录后，在弹出的窗口中完成 GitHub/Google 登录，\n应用将自动获取账号与 workspace 信息。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 登录主入口：内嵌浏览器完成登录，自动获取配置
            Button {
                model.startLogin()
            } label: {
                Label("使用浏览器登录", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isLoggingIn)

            if model.isLoggingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("请在打开的窗口中完成登录…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = model.loginErrorMessage {
                Text("⚠️ \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            // 设置区
            VStack(alignment: .leading, spacing: 12) {
                // 自动刷新频率（秒）
                VStack(alignment: .leading, spacing: 6) {
                    Text("自动刷新频率")
                        .font(.subheadline)
                    HStack(spacing: 8) {
                        TextField("300", value: $refreshIntervalSec, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .multilineTextAlignment(.trailing)
                        Text("秒")
                            .foregroundStyle(.secondary)
                        Stepper("", value: $refreshIntervalSec,
                                in: UsageModel.minRefreshInterval...UsageModel.maxRefreshInterval)
                            .labelsHidden()
                        Spacer()
                    }
                    Text("范围 \(UsageModel.minRefreshInterval)–\(UsageModel.maxRefreshInterval) 秒；过短可能触发服务端限流")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // 菜单栏显示哪个窗口
                VStack(alignment: .leading, spacing: 6) {
                    Text("菜单栏显示")
                        .font(.subheadline)
                    Picker("", selection: $menuBarDisplay) {
                        Text("自动（取最高用量）").tag("auto")
                        Text("5小时额度").tag("rolling")
                        Text("本周额度").tag("weekly")
                        Text("本月额度").tag("monthly")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("菜单栏图标上显示的百分比来源")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Spacer()
                    Button("保存设置") {
                        var c = Config.load()
                        c.refreshIntervalSec = max(
                            UsageModel.minRefreshInterval,
                            min(UsageModel.maxRefreshInterval, refreshIntervalSec)
                        )
                        c.menuBarDisplay = menuBarDisplay
                        model.saveConfig(c)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }

            Divider()

            HStack {
                Button("清除配置") {
                    model.saveConfig(Config.Stored())
                    onClose()
                }
                Spacer()
                Button("完成") { onClose() }
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            let c = Config.load()
            refreshIntervalSec = c.refreshIntervalSec
            menuBarDisplay = c.menuBarDisplay
        }
    }
}
