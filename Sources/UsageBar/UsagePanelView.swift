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
        .sheet(isPresented: Binding(
            get: { model.isConfigPresented },
            set: { model.isConfigPresented = $0 }
        )) {
            ConfigView(model: model)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Image(systemName: "bolt.fill")
                .foregroundStyle(model.menuBarColor)
            Text("OpenCode Go 用量")
                .font(.headline)
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

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .idle:
            VStack(spacing: 8) {
                Text("尚未配置 OpenCode Go")
                    .foregroundStyle(.secondary)
                Button("去配置") { model.isConfigPresented = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
                Button("重新配置") { model.isConfigPresented = true }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

        case .loaded(let data):
            VStack(spacing: 14) {
                ForEach(model.orderedWindows(from: data)) { w in
                    UsageRow(window: w, model: model)
                }
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            if case .loaded(let data) = model.status {
                Text("更新于 \(model.timeString(data.fetchedAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                model.isConfigPresented = true
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
