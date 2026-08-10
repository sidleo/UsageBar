import SwiftUI

// ==========================================
// 配置面板：仅浏览器登录（内嵌 WKWebView 自动捕获）
// ==========================================

struct ConfigView: View {
    @Environment(\.dismiss) private var dismiss
    let model: UsageModel

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

            HStack {
                Button("清除配置") {
                    model.saveConfig(Config.Stored())
                    dismiss()
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
