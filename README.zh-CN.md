<h1 align="center">Agent HUD</h1>

> **Windows 社区移植开发预览：**本分支在原项目基础上增加 Windows 源码移植。
> [Windows 安装与功能范围](windows/README.md) ·
> [Windows 宣传片](docs/videos/windows-preview.mp4) ·
> [差异审计与待办](windows/PARITY_AUDIT.md)。
> 下方保留原版 Mac 应用的介绍。本分支并非原作者官方 Windows 发行版，也不宣称全部功能已经对齐。

<p align="center">
  <strong>你的 Agent，抬眼可见。</strong><br>
  Claude Code、Codex 以及另外 16 款 agent 的用量、Token 与会话，就在 Mac 灵动岛或任意屏幕边缘。
</p>

<p align="center">
  <a href="https://agenthud.app/mac"><img src="docs/buttons/mac.zh-CN.svg" alt="下载 Mac 版 Agent HUD" width="180" height="36"></a>
  <a href="https://apps.apple.com/cn/app/agent-hud/id6812113619?uo=4"><img src="docs/buttons/app-store.svg" alt="从 App Store 获取 iPhone 与 Apple Watch App" width="138" height="36"></a>
  <a href="#从源码构建"><img src="docs/buttons/source.zh-CN.svg" alt="从源码构建 Agent HUD" width="181" height="36"></a>
</p>

<p align="center">
  <a href="#从源码构建"><img src="docs/badges/macos.svg" alt="macOS 14+" height="22"></a>
  <a href="Package.swift"><img src="docs/badges/swift.svg" alt="Swift 6" height="22"></a>
  <a href="LICENSE"><img src="docs/badges/license.svg" alt="Apache-2.0 许可证" height="22"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong> · <a href="https://agenthud.app">官网</a> · <a href="#支持的-agent">支持的 agent</a> · <a href="#文档">文档</a>
</p>

<p align="center">
  <img src="docs/videos/agent-hud-loop.zh-CN.webp" alt="灵动岛上的 Agent HUD 演示。光晕呼吸着红、黄、绿的额度色段；悬停后面板展开，显示 Claude 与 Codex 的额度、DeepSeek 的余额、过去 24 小时的 Token 与会话，点击后 Claude 的额度切换为消耗速率。随后 Claude 请求运行测试，用「批准一次」回应；它的回复以「有新回复」提醒出现，卡片上有「回到会话」" width="800">
</p>

Agent HUD 让你在使用其他应用时，也能看到各个编程 agent 的状态。

- **额度还剩多少？** 光晕随额度用量变为绿、黄、红。悬停即可看到具体数字。
- **哪个 agent 在等你？** 批准请求、提问与回复集中在一处，点一下就回到会话。
- **Token 花在了哪里？** 按时间、agent、模型、会话与轮次统计，并按 API 价折合费用。
- **离开 Mac 之后呢？** 同样的数字，在 iPhone 与 Apple Watch 上也能看到。

## 看一眼，或悬停一下

<p align="center">
  <img src="docs/videos/simple-mode-tour.zh-CN.webp" alt="简约形态停靠在屏幕左侧的一段演示。五个 agent 图标外是额度圆环，随后显示百分比与余额。悬停在图标上，用一行写出该 agent 的额度；点击后展开 Claude 的卡片，显示额度、消耗速率与 24 小时的 Token 柱。接着用 Allow once 回应一个批准请求，展开一条 New reply 提醒及其 Return to session 按钮，最后把 HUD 拖到屏幕顶部再拖回" width="800"><br>
  <sub>停靠在屏幕左侧的<a href="#bot形态与设置">简约形态</a>，已开启「按 agent 分开」 · 示例数据</sub>
</p>

**看一眼。** 光晕为每项额度（例如 5 小时或每周额度）显示一种颜色：已用不足 70% 为绿色，达到 70% 为黄色，达到 90% 为红色。在简约形态下，每个图标外的圆环也是如此。有 agent 在工作时，光晕动得更快。

**悬停一下。** 面板展开，给出具体数字：

- **额度**：每项的已用比例与重置倒计时，或它的消耗速率。
- **余额**：账户余额与预付余额，视 agent 而定。
- **Token**：过去 24 小时的用量，每 15 分钟一根柱。
- **会话**：最多五个，等你处理的排在最前。

**额度耗尽前会提醒你。** 用到 90% 时提醒；如果按当前速度撑不到重置，会更早提醒。

## 在灵动岛，也在每块屏幕上

- **带灵动岛的 MacBook**：Agent HUD 常驻灵动岛。
- **没有灵动岛的屏幕**：也有自己的 HUD，一排 agent 图标，可以拖到任意一条屏幕边缘。
- **每块屏幕**各自保存[形态](#bot形态与设置)、位置、大小与光晕。
- **请求与提醒**只出现在一块屏幕上：指针所在的那一块。

## 批准、提问与回复，集中一处

有 agent 需要你时，请求会停在 HUD 上，并附上所涉及的命令、文件、编辑差异或工具输入。不必切换窗口，直接在这里回答。

<p align="center">
  <img src="docs/screenshots/approvals.webp" alt="灵动岛上排着四个批准请求。第一个已展开：Avatar.tsx 的编辑差异、「Always allow adds Edit(src/**)」一行，以及 Deny、Always allow、Allow once 三个按钮" width="720">
</p>

- **批准**：**拒绝**、**批准一次**，agent 提供规则时还有**总是允许**。
- **提问**：选一个选项，或者自己输入。
- **回复**：一轮结束时出现**有新回复**提醒。
- **一键回到会话**：点击会话标题，或提醒上的**回到会话**，直接跳到它所在的线程、标签页或 iTerm2 窗格。

**Agent HUD 从不替你回答**：你没有处理的请求，10 分钟后交还 agent，由它自己询问。[各 agent 支持哪些功能](#支持的-agent)。

## Token 花在了哪里

统计窗口在这台 Mac 上保留 30 天的 Token 历史。

<p align="center">
  <a href="docs/screenshots/usage-statistics.webp"><img src="docs/screenshots/usage-statistics.webp" alt="统计窗口的 Token 页：堆叠的 Token 图表，带总量与按 API 价折合的费用；每个 agent 一张卡片，列出各类 Token 与费用；近期用量给出今天、近 7 天、近 30 天的费用与缓存命中率；最后是使用时段热图" width="468"></a> <a href="docs/screenshots/mac-session.webp"><img src="docs/screenshots/mac-session.webp" alt="一个 Claude Code 会话的页面：5200 万 Token，其中 600 万来自子 agent，按 API 价约 24.72 美元，26 轮、217 次调用，上下文 66%，缓存命中 99%；每轮 Token 图表中子 agent 的部分以淡色显示，第 22 轮已展开为逐次调用" width="330"></a><br>
  <sub>统计窗口的 Token 页与会话详情页 · 示例数据</sub>
</p>

- **按时间**：过去 5 小时、24 小时、7 天或 30 天，每根柱最细到 15 分钟。
- **按 agent 与模型**：每个 agent 一张卡片；图表可按模型和 Token 类型筛选。
- **按会话、轮次与调用**：每轮的 Token、上下文窗口用了多少，以及一轮中的每一次模型调用。
- **子 agent 与缓存**：子 agent 的 Token 计入所属会话；缓存命中率按时段、会话和模型给出。
- **折合多少钱**：按厂商的 API 价折合成费用（没有公开价的模型不计），并标 ≈。对订阅用户来说，这是估算，不是实际扣费。

## 在 iPhone 上

iPhone 与 Apple Watch 版 Agent HUD 显示 Mac 采集到的数据：额度、余额、Token 统计与会话，在 App、小组件和 Apple Watch 上都能看到。App 免费。

<p align="center">
  <a href="docs/screenshots/iphone-home.webp"><img src="docs/screenshots/iphone-home.webp" alt="iPhone 版 Agent HUD 的首页：Claude 与 Codex 的额度卡片，列出每个窗口的已用比例与重置时间，以及 DeepSeek 的账户余额" width="220"></a> <a href="docs/screenshots/iphone-sessions.webp"><img src="docs/screenshots/iphone-sessions.webp" alt="iPhone 版 Agent HUD 的会话页：今天各类 Token 的用量与费用，下方是带每轮柱状图与上下文占用的会话" width="220"></a><br>
  <sub>iPhone 版 Agent HUD · 首页与会话 · 示例数据</sub>
</p>

**同一局域网内，查看免费。** 在[官方 Mac 版](https://agenthud.app/mac)中打开「设置 → 局域网 → **分享此 Mac**」。登录同一 Apple 账户的 iPhone 会自动连接，其他 iPhone 扫描二维码即可配对。Mac 直接把数据交给手机，不经过 Agent HUD 的服务器。

## Agent HUD Remote

**唯一的付费功能**，用在离开 Mac 之后。它通过你自己的 iCloud 同步，还提供：

- **任何网络**：在 iPhone、小组件和 Apple Watch 上看到你的 Mac。
- **对话**：在手机上阅读 Claude Code、Codex、Grok CLI、Grok Bot 与 Antigravity 会话中的提示词与回复。
- **远程会话**（实验功能，需在 Mac 的「设置 → 实验选项」中打开）：在手机上允许或拒绝一次工具调用，并向 Claude Code 与 Codex 会话发送消息。见[指南](https://agenthud.app/guides/remote-sessions?lang=cn)。
- **提醒与实时活动**：iPhone 与 Apple Watch 上的提醒，以及锁定屏幕和 iPhone 灵动岛上运行中的会话。

后三项即使与 Mac 在同一局域网内，也需要 Agent HUD Remote。订阅按 Mac 台数计（1、2 或 3 台），按月或按年，首周免费；iPhone 与 Apple Watch 不占台数。在 iPhone App 内订阅（价格在那里显示），再到 Mac 上打开「设置 → 订阅 → **启用此 Mac**」。

## Bot、形态与设置

**Bot。** 每个 agent 的图标都有一个小 Bot，沿用图标自己的形状和颜色，带一双跟随指针的眼睛。需要你批准时它会跳一下，一轮完成时会微笑。[查看每个 agent 的 Bot](docs/videos/agent-bots.gif)。

**形态。** 每块屏幕从三种形态中选一种：有灵动岛的屏幕默认是刘海，其余默认是动态。

| 形&#8288;态 | 屏幕上的样子 |
| --- | --- |
| **刘&#8288;海** | 在刘海处，周围是光晕。 |
| **简&#8288;约** | 停靠在任意屏幕边缘的小型悬浮面板：每个 agent 的图标外套一个圆环，画的是它用量最高的那项额度，旁边写着百分比。 |
| **动&#8288;态** | 沿任意屏幕边缘排成一排的 agent 图标，背后是光晕。agent 工作时，它的图标会变成 Bot。 |

**设置。** 可以选择显示哪些账户与额度，每块屏幕的形态、大小与光晕，以及面板包含哪些内容。界面支持英文与简体中文。按 **⌘⌥H** 隐藏或显示光晕。

## 支持的 agent

安装并登录想要监测的 agent，Agent HUD 会自动发现它们。18 款都提供 Token 与会话。

| Agent | 额度 | 实时状态 | 批准 | 提问 | 回复 | 回到会话 | 轮次与调用 |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Claude&nbsp;Code** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Codex** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **DeepSeek&nbsp;Harness** | 余额 | ✓ |  | ✓ | ✓ |  | ✓ |
| **Antigravity** | ✓ |  | ✓ |  | ✓ | ✓ |  |
| **Cursor** | ✓ |  |  |  | ✓ |  |  |
| **Grok&nbsp;CLI** | ✓ | ✓ |  |  | ✓ | ✓ |  |
| **Grok&nbsp;Bot** | ✓ |  |  |  |  | ✓ |  |
| **GitHub&nbsp;Copilot&nbsp;CLI** | ✓ | ✓ |  |  | ✓ |  |  |
| **OpenCode** | ✓ |  |  |  | ✓ | ✓ |  |
| **Kimi** | ✓ | ✓ |  |  | ✓ |  |  |
| **Pi** | ✓ | ✓ |  |  | ✓ | ✓ |  |
| **OpenClaw** |  | ✓ |  |  | ✓ |  |  |
| **Hermes&nbsp;Agent** |  |  |  |  |  |  |  |
| **ZCode** |  |  | ✓ | ✓ |  |  |  |
| **CodeBuddy** |  |  | ✓ |  | ✓ |  |  |
| **WorkBuddy** |  |  | ✓ |  |  |  |  |
| **Qwen&nbsp;Code** |  |  | ✓ |  | ✓ |  |  |
| **Devin&nbsp;CLI** | ✓（缓存） | ✓ | ✓ |  | ✓ |  |  |

Devin 的每日与每周额度来自 CLI 的本机缓存；需在 CLI 中刷新，才能更新读数。

另外还读取 **GLM Coding Plan** 的额度，并支持批准 **Qoder** 系列的请求。Codex 的批准需先在 Codex 中信任回调，Copilot 的额度需先在设置中同意读取。其余见[各 agent 的详情](docs/providers.md)。

## 你的数据

- **在这台 Mac 上读取**：各 agent 已经保存的记录。用量历史保存在本机数据库中。
- **向各厂商读取**：额度、余额，以及 Cursor 的用量，使用 agent 现有的登录状态或已配置的密钥。任何一次读取都不会向模型发送消息，凭据不会被保存。
- **在这台 Mac 上写入**：agent 自己设置里的回调，用来接收请求与回复。「设置 → 通用」里的**客户端回调**开关可一并移除。
- **上传**：从本仓库源码构建的应用不上传任何数据。官方应用与你的 iPhone 共享、经由你的 iCloud 同步以及为实时活动发送的内容，见[隐私政策](https://agenthud.app/privacy?lang=cn)。

另见[数据访问](docs/data-access.md)。

## 从源码构建

**环境要求：** macOS 14+，以及包含 Swift 6 工具链的 Xcode 或 Xcode 命令行工具。

```sh
git clone https://github.com/jazzenchen/agent-hud-open.git
cd agent-hud-open
make check
make test
make run
```

以上命令会构建并打开 `build/Agent HUD Open.app`，使用临时签名供本机运行，无需开发者账户、签名身份或预置描述文件。想在没有安装任何 agent 时试用，先退出应用，再运行 `make demo`，它会用示例数据打开应用。

<details>
<summary><strong>开发与嵌入</strong></summary>

| 命令 | 用途 |
| --- | --- |
| `make check` / `make test` | 检查源码边界 / 运行单元测试 |
| `make build` / `make run` | 构建本机签名应用 / 构建并打开应用 |
| `make demo` / `make snapshot` | 用示例数据打开应用 / 将界面渲染到 `build/snapshots` |

Swift 包提供 `AgentHUDSupport`（记录与身份）、`AgentHUDCore`（数据源、模型与存储）和 `AgentHUDDesktop`（原生 HUD 与统计）。`AgentHUDOpen` 是独立可执行程序。宿主可通过 `DesktopApplication` 提供设置页面与服务，详见[宿主集成](docs/architecture.md#host-integration)。

持续集成检查源码边界、运行单元测试、构建应用，并验证签名与资源。

</details>

## 文档

[HUD 与批准](docs/hud.md) · [数据源](docs/providers.md) · [用量口径](docs/usage-semantics.md) · [会话生命周期](docs/session-lifecycle.md) · [会话跳转](docs/session-navigation.md) · [数据访问](docs/data-access.md) · [架构](docs/architecture.md) · [性能](docs/performance.md) · [命令行](docs/command-line.md) · [更新](docs/updates.md) · [品牌素材](docs/brand-assets.md) · [变更记录](CHANGELOG.md)

## 许可证

[Apache-2.0](LICENSE)。数据源引用与图标素材沿用各自的[第三方声明](THIRD_PARTY_NOTICES.txt)与[图标许可](Sources/AgentHUDDesktop/Resources/LobeIcons-LICENSE.txt)。

## Star 历史

<a href="https://www.star-history.com/?repos=jazzenchen%2Fagent-hud-open&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=jazzenchen/agent-hud-open&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=jazzenchen/agent-hud-open&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=jazzenchen/agent-hud-open&type=date&legend=top-left" />
 </picture>
</a>
