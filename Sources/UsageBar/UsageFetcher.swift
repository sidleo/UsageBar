import Foundation

// ==========================================
// OpenCode Go 用量抓取
//
// 官方 API（/zen/go/v1/usage，PR #16513）尚未部署，当前唯一可行方式：
//   GET https://opencode.ai/workspace/<wrk>/go
//   Cookie: auth=...
// 解析 SSR HTML 中 data-slot="usage-item" 块（Rolling/Weekly/Monthly）。
// 解析逻辑参考 v587d/pi-ocgo-usage（MIT）。
// ==========================================

struct UsageWindow: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case rolling, weekly, monthly

        var displayName: String {
            switch self {
            case .rolling: return "5小时额度"
            case .weekly: return "本周额度"
            case .monthly: return "本月额度"
            }
        }
    }

    let kind: Kind
    var id: Kind { kind }
    var percent: Int      // 0-100
    var resetInSec: Int   // 距重置剩余秒数
}

struct UsageData: Equatable {
    var windows: [UsageWindow] = []
    var fetchedAt: Date = Date()
}

enum UsageError: LocalizedError {
    case http(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return "请求失败 HTTP \(code)"
        case .parseFailed:
            return "解析失败（cookie 可能已过期，请重新配置）"
        }
    }
}

struct UsageFetcher {
    let baseURL: String
    let workspaceID: String
    let cookie: String

    // 关闭 URLSession 自动 cookie 管理：手动设置的 Cookie header 才能原样透传
    // （默认 HTTPCookieStorage 会覆盖/合并手动 Cookie，导致 SSR 页面认不出会话）
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg)
    }()

    func fetch() async throws -> UsageData {
        let escapedID = workspaceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workspaceID
        guard let url = URL(string: "\(baseURL)/workspace/\(escapedID)/go") else {
            throw UsageError.http(0)
        }
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, resp) = try await Self.session.data(for: req)
        let diag = ProcessInfo.processInfo.environment["USAGEBAR_DEBUG"] == "1"
        guard let http = resp as? HTTPURLResponse else {
            if diag { print("diag: 无 HTTP 响应"); fflush(stdout) }
            throw UsageError.http(0)
        }
        if diag { print("diag: status=\(http.statusCode) size=\(data.count) finalURL=\(http.url?.absoluteString ?? "?")"); fflush(stdout) }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else {
            if diag { print("diag: UTF-8 解码失败"); fflush(stdout) }
            throw UsageError.parseFailed
        }
        let windows = Self.parseSSR(html)
        if diag { print("diag: 解析窗口数=\(windows.count) htmlSize=\(html.count)"); fflush(stdout) }
        guard !windows.isEmpty else { throw UsageError.parseFailed }
        return UsageData(windows: windows, fetchedAt: Date())
    }

    // MARK: - SSR HTML 解析

    static func parseSSR(_ html: String) -> [UsageWindow] {
        let ns = html as NSString
        // 每个用量窗口是一个 <div data-slot="usage-item"> 块
        let itemRe = try? NSRegularExpression(pattern: #"<div[^>]*data-slot="usage-item""#)
        guard let itemRe else { return [] }
        let starts = itemRe.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var result: [UsageWindow] = []
        for i in 0..<starts.count {
            let start = starts[i].range.location
            let end = (i + 1 < starts.count) ? starts[i + 1].range.location : ns.length
            let block = ns.substring(with: NSRange(location: start, length: end - start))

            guard let label = capture(#"data-slot="usage-label"[^>]*>([^<]+)<"#, in: block),
                  let percentStr = capture(#"data-slot="usage-value"[\s\S]*?<!--\$-->\s*(\d+)\s*<!--/-->"#, in: block),
                  let percent = Int(percentStr) else { continue }

            let resetRaw = capture(#"data-slot="reset-time"[^>]*>([\s\S]*?)</span>"#, in: block) ?? ""
            let resetPhrase = resetRaw
                .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"重置于|Resets in"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let kind = kindFromLabel(label) else { continue }
            result.append(UsageWindow(
                kind: kind,
                percent: min(100, max(0, percent)),
                resetInSec: parseDurationToSec(resetPhrase)
            ))
        }
        return result
    }

    /// 兼容中英文 label：滚动/Rolling、每周/Weekly、每月/Monthly
    private static func kindFromLabel(_ label: String) -> UsageWindow.Kind? {
        let lower = label.lowercased()
        if lower.hasPrefix("rolling") || lower.hasPrefix("滚动") { return .rolling }
        if lower.hasPrefix("weekly") || lower.hasPrefix("每周") { return .weekly }
        if lower.hasPrefix("monthly") || lower.hasPrefix("每月") { return .monthly }
        return nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// 解析时长短语为秒数，兼容中英文："3 小时 3 分钟" / "3 hours 13 minutes"
    static func parseDurationToSec(_ phrase: String) -> Int {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty else { return 0 }
        let re = try? NSRegularExpression(pattern: #"(\d+)\s*(秒|分钟?|小时|天|周|月|年|second|minute|hour|day|week|month|year)s?"#)
        guard let re else { return 0 }
        let ns = p as NSString
        var total = 0
        var matched = false
        for m in re.matches(in: p, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 2, let n = Int(ns.substring(with: m.range(at: 1))) else { continue }
            matched = true
            switch ns.substring(with: m.range(at: 2)) {
            case "秒", "second": total += n
            case "分钟", "分", "minute": total += n * 60
            case "小时", "hour": total += n * 3600
            case "天", "day": total += n * 86400
            case "周", "week": total += n * 604800
            case "月", "month": total += n * 2_592_000  // 30 天近似
            case "年", "year": total += n * 31_536_000
            default: break
            }
        }
        return matched ? total : 0
    }
}
