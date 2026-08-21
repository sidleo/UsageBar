import SwiftUI

// ==========================================
// 点击菜单栏图标弹出的详情面板
// ==========================================

struct UsagePanelView: View {
    let model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 10)
            content
            Divider().padding(.vertical, 10)
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            // 服务切换（菜单栏当前显示哪个服务）
            Picker("", selection: Binding(
                get: { model.activeService },
                set: { newValue in
                    var c = Config.load()
                    c.activeService = newValue
                    model.saveConfig(c)
                }
            )) {
                Text("OpenCode").tag("opencode")
                Text("Command Code").tag("commandcode")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("切换菜单栏显示的服务")

            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("立即刷新")
        }
    }

    /// 当前服务显示名
    private var serviceTitle: String {
        model.activeService == "commandcode" ? "Command Code Go 用量" : "OpenCode Go 用量"
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        let st = model.activeStatus
        switch st {
        case .idle:
            VStack(spacing: 8) {
                Text(serviceTitle + (model.activeService == "commandcode" ? "（未登录）" : "（未配置）"))
                    .foregroundStyle(.secondary)
                if model.activeService == "commandcode" {
                    Text("请先在终端运行：cmd login")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Button("去配置") { model.openConfig() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("刷新中…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

        case .failed(let message):
            VStack(spacing: 8) {
                Text("⚠️ \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                if model.activeService == "commandcode" {
                    Text("提示：请在终端运行 cmd login 后刷新")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Button("重新配置") { model.openConfig() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

        case .loaded(let data):
            VStack(spacing: 14) {
                ForEach(model.orderedWindows(from: data)) { w in
                    UsageRow(window: w, model: model)
                }
                // Command Code 额外显示月 credits
                if model.activeService == "commandcode", let u = model.commandCodeUsage {
                    HStack {
                        Text("月 credits 剩余")
                            .font(.system(size: 13))
                        Spacer()
                        Text(String(format: "$%.2f / $%.2f", u.creditsRemaining, u.creditsTotal))
                            .font(.system(.body, design: .rounded).monospacedDigit())
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            if case .loaded(let data) = model.activeStatus {
                Text("更新于 \(model.timeString(data.fetchedAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                model.openConfig()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("配置")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("退出")
        }
    }
}

// ==========================================
// 单行用量：名称 + 百分比 + 进度条 + 剩余时间
// ==========================================

private struct UsageRow: View {
    let window: UsageWindow
    let model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.kind.displayName)
                    .font(.system(size: 13))
                Spacer()
                Text("\(window.percent)%")
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .bold()
            }
            ProgressView(value: Double(window.percent), total: 100)
                .tint(model.colorForPercent(window.percent))
            Text("重置剩余 \(model.formatReset(window.resetInSec))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
