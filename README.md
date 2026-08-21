# UsageBar — macOS 菜单栏 Token 用量查看器

菜单栏直接显示当前服务（OpenCode Go / Command Code Go）的用量百分比，
点击弹出详情面板：用量进度条 + 百分比 + 重置剩余时间。颜色随用量变化（绿 → 橙 → 红）。

## 功能

- **双服务支持**：OpenCode Go 与 Command Code Go 用量查看，面板顶部一键切换菜单栏显示的服务
- **菜单栏显示**：默认取最高用量；可在 ⚙ 中自定义显示 5小时/周/月 任一窗口的百分比
- **菜单栏图标**：直接显示用量百分比，颜色编码：
  - 绿色：< 60%
  - 橙色：60% - 89%
  - 红色：≥ 90%（或已触顶）
- **点击弹出详情**：5小时额度 / 本周额度 / 本月额度 的进度条、百分比、重置剩余时间
- **自动刷新**：默认每 5 分钟一次；可在 ⚙ 中自定义刷新频率（30–86400 秒）；面板内可手动刷新
- **刷新频率可调**：⚙ →「自动刷新频率」输入秒数（如 60 = 每分钟），保存后立即生效
- **配置界面**：OpenCode 首次使用点 ⚙ →「使用浏览器登录」，内嵌窗口完成登录后自动配置
- **安全存储**：OpenCode 的 cookie（完整登录会话，等同密码）存 Keychain，不落盘明文；Command Code 的 API key 只读本机 `~/.commandcode/auth.json`（cmd CLI 登录产生），不存储不外传

## 快速开始

### 1. 构建（已装 Xcode，一行命令）

```bash
cd UsageBar
./build-app.sh        # 产物: build/UsageBar.app
open build/UsageBar.app
```

### 2. 配置 OpenCode Go（只需一次，cookie 有效期 1 年）

**仅支持应用内登录，无需手动复制任何信息**：

1. 点击菜单栏图标 → ⚙ → 「使用浏览器登录」
2. 在弹出的登录窗口中完成 GitHub/Google 登录（与 opencode.ai 账号一致）
3. 登录成功后自动获取 workspace ID 和会话，窗口自动关闭即完成配置

> 若登录窗口被关闭而未完成，重新点「使用浏览器登录」即可。
> 登录过程中点击窗口外部不会关闭窗口；点红 X 可取消。
> ⚠️ 会话 cookie 等同密码，应用内登录后自动存入 Keychain，不会外传。

### 3. 配置 Command Code Go

Command Code Go 与 OpenCode 是**独立产品**（commandcode.ai），需独立登录：

1. 安装 CLI 并登录（一次性）：`npm install -g command-code && cmd login`
2. 登录后 API key 自动写入 `~/.commandcode/auth.json`
3. UsageBar 自动检测，面板顶部切换到「Command Code」即显示用量

> Command Code 用量走官方 API（`api.commandcode.ai`），Bearer API Key 认证，
> key 从 `~/.commandcode/auth.json` 的 `apiKey` 字段读取，**不存储不外传**。
> 未登录时面板提示「请先运行 cmd login」。

## 工作原理

### OpenCode Go

订阅额度限制（官方文档）：

| 窗口 | 额度 |
|------|------|
| 5小时（滚动） | $12 |
| 每周 | $30 |
| 每月 | $60 |

官方用量 API（`/zen/go/v1/usage`，PR #16513 已合并但未部署，实测 404）尚未上线，
当前通过抓取控制台 SSR 页面获取。**应用内登录**使用内嵌 WKWebView 走 opencode.ai
的 OAuth 授权码流（openauth.js，Google/GitHub），登录成功后自动捕获会话 cookie
与 workspace ID：

```
GET https://opencode.ai/workspace/<wrk>/go
Cookie: auth=...
```

解析页面中 `data-slot="usage-item"` 块（兼容中英文：`滚动用量/每周用量/每月用量` 与
`Rolling Usage/Weekly Usage/Monthly Usage`）。官方 API 上线后可无缝切换。

### Command Code Go

Command Code（commandcode.ai）是独立产品，用量走官方 API：

```
Base: https://api.commandcode.ai
Auth: Authorization: Bearer <apiKey>   (apiKey 来自 ~/.commandcode/auth.json)
```

| 步骤 | 接口 | 用途 |
|------|------|------|
| 1 | `GET /alpha/whoami` | 获取 org.id |
| 2 | `GET /alpha/billing/credits?orgId=` | 计划与月 credits |
| 3 | `GET /alpha/billing/subscriptions?orgId=` | 月周期起止 |
| 4 | `GET /alpha/usage/summary?orgId=&since=` | **5小时/周窗口**（used/cap/resetAt） |

窗口数据：`summary.fiveHour`（5小时窗口）、`summary.weekly`（周窗口），
月用量由 credits 消耗百分比计算。端点与字段名来自 command-code CLI 源码
（v1.31.0，npm 包 `dist/cli.mjs` 静态分析）。

## 目录结构

```
UsageBar/
├── Package.swift              # SPM 配置（macOS 14+）
├── Info.plist                 # LSUIElement: 菜单栏 app，无 Dock 图标
├── build-app.sh               # 构建 + 组装 .app + 签名
└── Sources/UsageBar/
    ├── UsageBarApp.swift      # 入口：MenuBarExtra + 图标文字
    ├── UsageModel.swift       # 状态管理（双服务）+ 定时刷新 + 排障日志
    ├── UsageFetcher.swift     # OpenCode：HTTP 抓取 + SSR HTML 解析（中英双语）
    ├── CommandCodeFetcher.swift  # Command Code：Bearer API + 窗口解析
    ├── UsagePanelView.swift   # 详情面板 UI（服务切换 + 进度条）
    ├── ConfigView.swift       # 配置面板（仅浏览器登录 + 设置项）
    ├── LoginWindowController.swift  # 内嵌 WKWebView 登录 + 自动捕获
    └── Config.swift           # UserDefaults + Keychain 存储
```

## 排障

- **显示 `…`**：当前服务未配置/未登录或加载中。OpenCode 点 ⚙ 重新配置；Command Code 先 `cmd login`
- **显示 ⚠️ 解析失败**：OpenCode cookie 可能过期；Command Code apiKey 可能失效，重新登录
- **Command Code 显示认证失败**：`~/.commandcode/auth.json` 的 apiKey 失效，重新 `cmd login`
- **刷新太频繁被限流**：⚙ 中把刷新频率调大（默认 300 秒，勿低于 30 秒）
- **查看运行日志**：`USAGEBAR_DEBUG=1` 启动后查看 `~/Library/Logs/UsageBar.log`
- **重置配置**：面板 ⚙ 中点「清除配置」

## 后续扩展方向

- 开机自启（SMAppService / LaunchAgent）
- 官方 `/zen/go/v1/usage` API 上线后自动切换
- 接入其他订阅（Anthropic、OpenAI 等）用量
