import SwiftUI
import Observation

// ==========================================
// 用量状态管理：启动即刷新，每 5 分钟自动刷新
// ==========================================

@MainActor
@Observable
final class UsageModel {
    enum Status: Equatable {
        case idle          // 未配置
        case loading
        case loaded(UsageData)
        case failed(String)
    }

    var status: Status = .idle
    var isConfigPresented = false
    var loginErrorMessage: String?
    var isLoggingIn = false

    private var timer: Timer?
    private var loginController: LoginWindowController?
    private let refreshInterval: TimeInterval = 300  // 5 分钟

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        Task { await refresh() }
        // 排障钩子：USAGEBAR_AUTO_LOGIN=1 启动时自动弹出登录窗口
        if ProcessInfo.processInfo.environment["USAGEBAR_AUTO_LOGIN"] == "1" {
            Task { startLogin() }
        }
    }

    func refresh() async {
        let cfg = Config.load()
        Self.debugLog("配置检查: wsID=\(cfg.workspaceID), cookieLen=\(cfg.cookie.count), cookiePrefix=\(cfg.cookie.prefix(12))")
        guard cfg.isComplete else {
            status = .idle
            Self.debugLog("未配置，跳过刷新")
            return
        }
        status = .loading
        do {
            let data = try await UsageFetcher(
                baseURL: cfg.baseURL,
                workspaceID: cfg.workspaceID,
                cookie: cfg.cookie
            ).fetch()
            status = .loaded(data)
            Self.debugLog("刷新成功: " + data.windows.map { "\($0.kind.rawValue)=\($0.percent)%" }.joined(separator: " "))
        } catch {
            status = .failed(error.localizedDescription)
            Self.debugLog("刷新失败: \(error)")
        }
    }

    /// 排障日志：仅 USAGEBAR_DEBUG=1 时写入 ~/Library/Logs/UsageBar.log
    static func debugLog(_ msg: String) {
        guard ProcessInfo.processInfo.environment["USAGEBAR_DEBUG"] == "1" else { return }
        let line = "[\(Date())] \(msg)\n"
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

    // MARK: - 登录

    /// 弹出内嵌浏览器登录窗口，成功后自动保存配置并刷新
    func startLogin() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        loginErrorMessage = nil
        let controller = LoginWindowController()
        loginController = controller
        controller.start { [weak self] result in
            guard let self else { return }
            self.isLoggingIn = false
            self.loginController = nil
            switch result {
            case .success(let r):
                Self.debugLog("登录成功: workspace=\(r.workspaceID) cookieLen=\(r.cookie.count)")
                self.saveConfig(Config.Stored(
                    workspaceID: r.workspaceID,
                    baseURL: "https://opencode.ai",
                    cookie: r.cookie
                ))
                self.isConfigPresented = false
            case .failure(let e):
                Self.debugLog("登录取消/失败: \(e.localizedDescription)")
                // 用户主动关闭窗口视为取消，不提示错误；其余失败才提示
                if let le = e as? LoginWindowController.LoginError, le == .userClosed {
                    loginErrorMessage = nil
                } else {
                    loginErrorMessage = e.localizedDescription
                }
            }
        }
    }

    // MARK: - 菜单栏显示（图标直接显示最高用量百分比）

    private var maxPercent: Int? {
        guard case .loaded(let data) = status else { return nil }
        return data.windows.map(\.percent).max()
    }

    var menuBarText: String {
        if let p = maxPercent { return "\(p)%" }
        return "…"  // 未配置 / 加载中 / 失败
    }

    var menuBarColor: Color {
        colorForPercent(maxPercent)
    }

    func colorForPercent(_ pct: Int?) -> Color {
        guard let pct else { return .secondary }
        if pct >= 90 { return .red }
        if pct >= 60 { return .orange }
        return .green
    }

    // MARK: - 配置

    func saveConfig(_ c: Config.Stored) {
        Config.save(c)
        Task { await refresh() }
    }

    /// 按固定顺序返回窗口（5小时 → 本周 → 本月）
    func orderedWindows(from data: UsageData) -> [UsageWindow] {
        var map: [UsageWindow.Kind: UsageWindow] = [:]
        for w in data.windows { map[w.kind] = w }
        return UsageWindow.Kind.allCases.compactMap { map[$0] }
    }

    /// 秒数格式化为中文剩余时间
    func formatReset(_ sec: Int) -> String {
        if sec <= 0 { return "即将重置" }
        let d = sec / 86_400
        let h = (sec % 86_400) / 3_600
        let m = (sec % 3_600) / 60
        if d > 0 { return "\(d)天 \(h)小时" }
        if h > 0 { return "\(h)小时 \(m)分" }
        if m > 0 { return "\(m)分钟" }
        return "\(sec)秒"
    }

    func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
