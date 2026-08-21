import Foundation

// ==========================================
// Command Code Go 用量获取
//
// 认证：Bearer API Key
//   - 来源：~/.commandcode/auth.json 的 apiKey 字段（cmd CLI 登录后写入）
//   - 或环境变量 COMMANDCODE_API_KEY
// 接口（base: https://api.commandcode.ai）：
//   1. GET /alpha/whoami                       → org.id
//   2. GET /alpha/billing/credits?orgId=       → 计划/credits 信息
//   3. GET /alpha/billing/subscriptions?orgId= → currentPeriodStart/End
//   4. GET /alpha/usage/summary?orgId=&since=  → fiveHour/weekly 窗口 (used/cap/resetAt)
// 端点与字段名来自 command-code CLI 源码（v1.31.0，npm 包 dist/cli.mjs）
// ==========================================

/// Command Code 用量（含月 credits 信息）
struct CommandCodeUsage: Equatable {
    var windows: [UsageWindow] = []      // rolling(fiveHour) + weekly，可能含 monthly(credits%)
    var creditsRemaining: Double = 0     // 月剩余 credits（$）
    var creditsTotal: Double = 0         // 月总 credits（$）
    var periodEnd: Date?                 // 月周期结束（用于 monthly 重置时间）
    var fetchedAt: Date = Date()
}

enum CommandCodeError: LocalizedError {
    case notLoggedIn           // 未找到 auth.json / apiKey
    case http(Int)
    case api(String)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "未检测到 Command Code 登录（请先运行 cmd login）"
        case .http(let code):
            return "Command Code 请求失败 HTTP \(code)"
        case .api(let msg):
            return "Command Code 接口错误: \(msg)"
        case .parseFailed:
            return "Command Code 解析失败"
        }
    }
}

struct CommandCodeFetcher {
    private static let baseURL = "https://api.commandcode.ai"
    private static let authFile = NSHomeDirectory() + "/.commandcode/auth.json"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg)
    }()

    // MARK: - 入口

    func fetch() async throws -> CommandCodeUsage {
        guard let apiKey = Self.readApiKey() else {
            throw CommandCodeError.notLoggedIn
        }
        let client = Self.client(apiKey: apiKey)

        // 1. whoami → org.id
        struct Whoami: Decodable {
            struct Org: Decodable { let id: String }
            let org: Org?
        }
        let whoami: Whoami = try await client.get("/alpha/whoami")
        guard let orgId = whoami.org?.id, !orgId.isEmpty else {
            throw CommandCodeError.parseFailed
        }

        // 2+3. credits + subscription（并行）
        let orgQuery = "orgId=\(orgId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgId)"
        struct Credits: Decodable {
            struct Inner: Decodable {
                let planId: String?
                let monthlyCredits: Double?
                let purchasedCredits: Double?
                let freeCredits: Double?
            }
            let credits: Inner?
        }
        struct Subscription: Decodable {
            struct Inner: Decodable {
                let planId: String?
                let status: String?
                let currentPeriodStart: String?
                let currentPeriodEnd: String?
            }
            let data: Inner?
        }
        async let creditsResult = client.getOptional("/alpha/billing/credits?\(orgQuery)", as: Credits.self)
        async let subResult = client.getOptional("/alpha/billing/subscriptions?\(orgQuery)", as: Subscription.self)
        let (credits, subscription) = try await (creditsResult, subResult)

        // 4. summary：since = currentPeriodStart
        let since = subscription?.data?.currentPeriodStart ?? ""
        struct Summary: Decodable {
            struct Window: Decodable {
                let used: Double?
                let cap: Double?
                let resetAt: String?
            }
            let fiveHour: Window?
            let weekly: Window?
            let totalCost: Double?
        }
        let sinceQuery = since.isEmpty ? "" : "&since=\(since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? since)"
        let summary: Summary? = try await client.getOptional("/alpha/usage/summary?\(orgQuery)\(sinceQuery)", as: Summary.self)

        // 组装
        var windows: [UsageWindow] = []
        let now = Date()
        let df = ISO8601DateFormatter()
        func secUntilReset(_ s: String?) -> Int {
            guard let s, let d = df.date(from: s) else { return 0 }
            return max(0, Int(d.timeIntervalSince(now)))
        }
        func window(_ kind: UsageWindow.Kind, _ w: Summary.Window?) -> UsageWindow? {
            guard let w, let cap = w.cap, cap > 0 else { return nil }
            let used = w.used ?? 0
            return UsageWindow(
                kind: kind,
                percent: min(100, max(0, Int((used / cap * 100).rounded()))),
                resetInSec: secUntilReset(w.resetAt)
            )
        }
        if let w = window(.rolling, summary?.fiveHour) { windows.append(w) }
        if let w = window(.weekly, summary?.weekly) { windows.append(w) }

        // 月 credits：monthlyRemaining / total
        let monthly = credits?.credits?.monthlyCredits ?? 0
        let purchased = credits?.credits?.purchasedCredits ?? 0
        let free = credits?.credits?.freeCredits ?? 0
        let total = monthly + purchased + free
        let spent = summary?.totalCost ?? 0
        let remaining = max(0, total - spent)
        if total > 0 {
            let pct = min(100, max(0, Int(((total - remaining) / total * 100).rounded())))
            let end = subscription?.data?.currentPeriodEnd
            windows.append(UsageWindow(
                kind: .monthly,
                percent: pct,
                resetInSec: secUntilReset(end)
            ))
        }

        return CommandCodeUsage(
            windows: windows,
            creditsRemaining: remaining,
            creditsTotal: total,
            periodEnd: subscription?.data?.currentPeriodEnd.flatMap { df.date(from: $0) },
            fetchedAt: now
        )
    }

    // MARK: - API key 读取

    /// 读取 API key：环境变量优先，其次 ~/.commandcode/auth.json
    static func readApiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["COMMANDCODE_API_KEY"],
           !env.isEmpty {
            return env
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authFile)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["apiKey"] as? String,
              !key.isEmpty else {
            return nil
        }
        return key
    }

    /// 是否已登录（auth.json 存在且有 apiKey）
    static func isLoggedIn() -> Bool {
        readApiKey() != nil
    }

    // MARK: - HTTP client

    private static func client(apiKey: String) -> Client {
        Client(apiKey: apiKey)
    }

    private struct Client {
        let apiKey: String

        func get<T: Decodable>(_ path: String) async throws -> T {
            guard let url = URL(string: baseURL + path) else { throw CommandCodeError.http(0) }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw CommandCodeError.http(0) }
            guard http.statusCode == 200 else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw CommandCodeError.api("认证失败（apiKey 可能已失效，请重新 cmd login）")
                }
                throw CommandCodeError.http(http.statusCode)
            }
            guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                throw CommandCodeError.parseFailed
            }
            return decoded
        }

        /// 可选请求：失败（如 404/空）返回 nil，不阻断流程
        func getOptional<T: Decodable>(_ path: String, as: T.Type) async throws -> T? {
            guard let url = URL(string: baseURL + path) else { return nil }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }
}
