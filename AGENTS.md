# UsageBar 项目规范

> macOS 菜单栏 Token 用量查看器：显示 OpenCode Go 订阅用量（5小时/周/月额度）。

## 构建与运行

```bash
./build-app.sh              # 构建 + 组装 build/UsageBar.app + ad-hoc 签名
open build/UsageBar.app     # 运行
cp -R build/UsageBar.app /Applications/   # 安装（先 pkill 退出运行中的实例）
```

- 纯 Swift + SwiftUI + WebKit，SPM 构建，**无第三方依赖**
- 需 macOS 14+（MenuBarExtra），本机 macOS 26 / Swift 6.3

## 架构

| 文件 | 职责 |
|------|------|
| `UsageBarApp.swift` | 入口：MenuBarExtra，图标直接显示最高用量百分比，颜色绿/橙/红 |
| `UsageModel.swift` | 状态机（idle/loading/loaded/failed）、5 分钟定时刷新、登录流程编排、排障日志 |
| `UsageFetcher.swift` | HTTP 抓取 SSR 页面 + 正则解析（**必须兼容中英文** label：`滚动用量`/`Rolling Usage` 等） |
| `LoginWindowController.swift` | 内嵌 WKWebView OAuth 登录，自动捕获 auth cookie + workspace ID |
| `ConfigView.swift` | 配置面板（仅浏览器登录入口 + 清除配置） |
| `Config.swift` | 配置存储：workspaceID/baseURL 在 UserDefaults，**cookie 在 Keychain** |

## 关键约定

1. **cookie 等同密码**：只存 Keychain，绝不写入代码/日志/README/提交历史
2. **数据来源**：`GET https://opencode.ai/workspace/<wrk>/go` + `Cookie: auth=...`，
   官方 `/zen/go/v1/usage` API（PR #16513）未部署前不可用，SSR 抓取是唯一途径
3. **URLSession 必须禁用自动 cookie 管理**（`httpShouldSetCookies = false`），
   否则手动 Cookie header 被覆盖导致认证失败
4. **登录窗口必须** `hidesOnDeactivate = false` + `isFloatingPanel = true`
   （否则点击外部窗口会消失）；关闭回调用 `NSWindowDelegate.windowWillClose(_:)`（带参）
5. 解析逻辑与 [v587d/pi-ocgo-usage](https://github.com/v587d/pi-ocgo-usage)（MIT）同源，
   改解析前先抓真实 HTML 验证正则（中文页面 vs 英文页面结构不同）

## 排障

```bash
USAGEBAR_DEBUG=1 ./build/UsageBar.app/Contents/MacOS/UsageBar
# 日志: ~/Library/Logs/UsageBar.log（配置检查、刷新结果、登录流程）
```

- 菜单栏显示 `…`：未配置；`⚠️ 解析失败`：cookie 失效，重登录
- 环境变量 `USAGEBAR_AUTO_LOGIN=1`：启动时自动弹登录窗口（排障用）

## 数据安全

- 禁止向 GitHub 提交：auth cookie、API key、workspace ID（`.gitignore` 只排除构建产物，
  敏感信息靠"不写入源码"保证）
- 修改 Keychain 存储逻辑需保持 `kSecAttrService = "com.zhang3.usagebar"` 不变，
  否则已配置用户的登录态丢失
