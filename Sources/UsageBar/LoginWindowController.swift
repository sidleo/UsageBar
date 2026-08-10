import AppKit
import WebKit

// ==========================================
// 内嵌浏览器登录：用户在 WKWebView 中完成
// opencode.ai 登录（OAuth → Google/GitHub），
// 登录后自动捕获 auth cookie 和 workspace ID，
// 无需手动复制任何信息。
// ==========================================

@MainActor
final class LoginWindowController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var panel: NSPanel?
    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var completion: ((Result<LoginResult, Error>) -> Void)?
    private var extractingWorkspace = false  // 提取进行中
    private var lastExtractAt = Date.distantPast  // 提取限频
    private var lastCookieValue = ""
    private var done = false
    private var lastLoggedURL: String?

    struct LoginResult {
        let cookie: String
        let workspaceID: String
    }

    enum LoginError: LocalizedError, Equatable {
        case userClosed
        case noWorkspace
        case httpRequest

        var errorDescription: String? {
            switch self {
            case .userClosed: return "登录窗口已关闭"
            case .noWorkspace: return "未能获取 workspace ID，请重试登录"
            case .httpRequest: return "网络请求失败"
            }
        }
    }

    func start(completion: @escaping (Result<LoginResult, Error>) -> Void) {
        self.completion = completion

        // WKWebView：使用隔离的 ephemeral cookie store——
        // 避免系统共享的旧 opencode 会话（无效 cookie）干扰登录流程，
        // 用户看到的是干净的登录选择页。登录后 cookie 从本 store 读取。
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        self.webView = webView

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "登录 OpenCode"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.hidesOnDeactivate = false   // 点击外部/app 失活时不隐藏
        panel.isFloatingPanel = true      // 浮动面板：失活后仍显示在最上层
        panel.contentView = webView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        LoginWindowController.debugLog("登录窗口已打开，加载 /auth")

        // 加载 /auth：未登录 302 到 auth.opencode.ai 登录选择页（Google/GitHub）
        // 已登录则直接进入 opencode.ai 并携带 auth cookie
        webView.load(URLRequest(url: URL(string: "https://opencode.ai/auth")!))

        // 每秒轮询 auth cookie + workspace，直到完成
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.poll() }
        }
    }

    // MARK: - 轮询

    private func poll() async {
        guard !done, let webView else { return }

        // 1. 读取持久 cookie store 中的 auth cookie
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()

        // 加载状态日志（仅 URL 变化时打印）
        let currentURL = webView.url?.absoluteString ?? "(nil)"
        if currentURL != lastLoggedURL {
            lastLoggedURL = currentURL
            Self.debugLog("webView URL: \(currentURL) loading=\(webView.isLoading) cookies=\(cookies.map { "\($0.name):\($0.domain):\($0.value.prefix(8))..." }.joined(separator: ", "))")
        }

        // 只认 opencode.ai 主域的 auth cookie（登录前后都存在，登录后值变为有效会话）
        guard let auth = cookies.first(where: {
            $0.name == "auth" && !$0.value.isEmpty && $0.domain.contains("opencode.ai")
        }) else { return }
        let cookieStr = "auth=\(auth.value)"

        // 2. 先试从当前 URL 提取 workspace ID
        if let ws = extractWorkspace(from: webView.url) {
            finish(cookie: cookieStr, workspaceID: ws)
            return
        }

        // 3. URLSession 提取：cookie 值变化才重试，且限频 3 秒
        guard !extractingWorkspace, auth.value != lastCookieValue,
              Date().timeIntervalSince(lastExtractAt) > 3 else { return }
        lastCookieValue = auth.value
        extractingWorkspace = true
        lastExtractAt = Date()
        Self.debugLog("检测到 opencode.ai auth cookie（可能为临时会话），请求 /go 验证...")
        do {
            let html = try await fetchGoPage(cookie: cookieStr)
            if let ws = extractWorkspace(from: html) {
                Self.debugLog("提取 workspace 成功: \(ws)")
                finish(cookie: cookieStr, workspaceID: ws)
            } else {
                // 临时会话：等用户完成 GitHub/Google 登录后 cookie 更新，不打断登录流程
                Self.debugLog("auth 为临时会话（用户尚未完成登录），继续等待...")
                extractingWorkspace = false
            }
        } catch {
            extractingWorkspace = false
            Self.debugLog("请求 /go 失败: \(error.localizedDescription)，稍后重试")
        }
    }

    /// 带 cookie 请求 /go 总览页，HTML 中含 workspace ID
    private func fetchGoPage(cookie: String) async throws -> String {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: URL(string: "https://opencode.ai/go")!)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw LoginError.httpRequest
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Self.debugLog("开始导航: \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.debugLog("导航失败: \(error.localizedDescription) url=\(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.debugLog("页面加载完成: \(webView.url?.absoluteString ?? "?")")
        // 触发一次 poll，及时处理 /go 页面已加载的情况
        Task { @MainActor in await self.poll() }
    }

    // MARK: - 提取

    /// 从 URL 或 HTML 中提取 wrk_ 开头的 workspace ID
    private func extractWorkspace(from text: Any?) -> String? {
        guard let text else { return nil }
        let source: String
        if let url = text as? URL {
            source = url.absoluteString
        } else if let s = text as? String {
            source = s
        } else {
            return nil
        }
        guard let re = try? NSRegularExpression(pattern: #"wrk_[A-Za-z0-9]{8,}"#) else { return nil }
        let ns = source as NSString
        guard let m = re.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 0))
    }

    // MARK: - 日志

    static func debugLog(_ msg: String) {
        guard ProcessInfo.processInfo.environment["USAGEBAR_DEBUG"] == "1" else { return }
        let line = "[登录] \(msg)\n"
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

    // MARK: - 完成/取消

    private func finish(cookie: String, workspaceID: String) {
        guard !done else { return }
        done = true
        pollTimer?.invalidate()
        pollTimer = nil
        panel?.close()
        panel = nil
        completion?(.success(LoginResult(cookie: cookie, workspaceID: workspaceID)))
    }

    /// NSWindowDelegate：用户点击关闭按钮（X）关闭窗口时触发
    func windowWillClose(_ notification: Notification) {
        guard !done else { return }
        done = true
        pollTimer?.invalidate()
        pollTimer = nil
        completion?(.failure(LoginError.userClosed))
    }
}
