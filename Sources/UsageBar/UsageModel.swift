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

    var status: Status = .idle                 // OpenCode Go 状态
    var commandCodeStatus: Status = .idle      // Command Code Go 状态
    var commandCodeUsage: CommandCodeUsage?    // Command Code 额外信息（credits）
    var loginErrorMessage: String?
    var isLoggingIn = false

    private var timer: Timer?
    private var loginController: LoginWindowController?
    private var configController: ConfigWindowController?

    /// 刷新间隔上下限（秒）：过短可能触发 opencode.ai 服务端限流
    static let minRefreshInterval = 30
    static let maxRefreshInterval = 86400

    init() {
        restartTimer()
        Task { await refresh() }
        // 排障钩子：USAGEBAR_AUTO_LOGIN=1 启动时自动弹出登录窗口
        if ProcessInfo.processInfo.environment["USAGEBAR_AUTO_LOGIN"] == "1" {
            Task { startLogin() }
        }
        // 排障钩子：USAGEBAR_OPEN_CONFIG=1 启动时自动打开配置窗口
        if ProcessInfo.processInfo.environment["USAGEBAR_OPEN_CONFIG"] == "1" {
            Task { openConfig() }
        }
    }

    /// 按当前配置的刷新间隔（秒）重启定时器
    func restartTimer() {
        timer?.invalidate()
        timer = nil
        let sec = max(Self.minRefreshInterval, min(Self.maxRefreshInterval, Config.load().refreshIntervalSec))
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(sec), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        Self.debugLog("刷新间隔设置为 \(sec) 秒")
    }

    func refresh() async {
        // 并行刷新两个服务
        async let opencode: Void = refreshOpencode()
        async let commandcode: Void = refreshCommandCode()
        _ = await (opencode, commandcode)
    }

    private func refreshOpencode() async {
        let cfg = Config.load()
        Self.debugLog("配置检查: wsID=\(cfg.workspaceID), cookieLen=\(cfg.cookie.count), cookiePrefix=\(cfg.cookie.prefix(12))")
        guard cfg.isComplete else {
            status = .idle
            Self.debugLog("OpenCode 未配置，跳过刷新")
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
            Self.debugLog("OpenCode 刷新成功: " + data.windows.map { "\($0.kind.rawValue)=\($0.percent)%" }.joined(separator: " "))
        } catch {
            status = .failed(error.localizedDescription)
            Self.debugLog("OpenCode 刷新失败: \(error)")
        }
    }

    private func refreshCommandCode() async {
        guard CommandCodeFetcher.isLoggedIn() else {
            commandCodeStatus = .idle
            Self.debugLog("Command Code 未登录，跳过刷新")
            return
        }
        commandCodeStatus = .loading
        do {
            let usage = try await CommandCodeFetcher().fetch()
            commandCodeUsage = usage
            commandCodeStatus = .loaded(UsageData(
                windows: usage.windows,
                fetchedAt: usage.fetchedAt
            ))
            Self.debugLog("Command Code 刷新成功: " + usage.windows.map { "\($0.kind.rawValue)=\($0.percent)%" }.joined(separator: " ") + " | credits 剩余 $\(usage.creditsRemaining)/$\(usage.creditsTotal)")
        } catch {
            commandCodeStatus = .failed(error.localizedDescription)
            Self.debugLog("Command Code 刷新失败: \(error)")
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

    // MARK: - 配置窗口

    /// 打开独立配置窗口（不随菜单栏面板关闭）
    func openConfig() {
        if configController == nil {
            configController = ConfigWindowController(model: self)
        }
        Self.debugLog("openConfig 调用")
        configController?.show()
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
                self.configController?.close()  // 登录完成，关闭配置窗口
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

    // MARK: - 菜单栏显示（按配置选择服务与窗口）

    /// 当前激活的服务（配置 activeService）
    var activeService: String {
        Config.load().activeService
    }

    /// 当前服务的状态（按 activeService）
    var activeStatus: Status {
        activeService == "commandcode" ? commandCodeStatus : status
    }

    /// 菜单栏显示值：根据配置的 menuBarDisplay 选择窗口，auto 取最高
    private func menuBarPercent() -> Int? {
        guard case .loaded(let data) = activeStatus else { return nil }
        let windows = orderedWindows(from: data)
        switch Config.load().menuBarDisplay {
        case "rolling":
            return windows.first { $0.kind == .rolling }?.percent
        case "weekly":
            return windows.first { $0.kind == .weekly }?.percent
        case "monthly":
            return windows.first { $0.kind == .monthly }?.percent
        default:  // auto
            return windows.map(\.percent).max()
        }
    }

    var menuBarText: String {
        if let p = menuBarPercent() { return "\(p)%" }
        return "…"  // 未配置 / 加载中 / 失败
    }

    var menuBarColor: Color {
        colorForPercent(menuBarPercent())
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
        restartTimer()  // 刷新间隔可能变化，重启定时器
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
