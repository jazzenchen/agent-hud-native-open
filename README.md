<h1 align="center">agent-hud-native-open</h1>

<p align="center">
  <strong>Agent HUD has moved to <a href="https://github.com/jazzenchen/agent-hud-open">jazzenchen/agent-hud-open</a>.</strong><br>
  This repository holds its earlier Swift app for macOS. It gets limited maintenance and sometimes experimental features.
</p>

<p align="center">
  <a href="#build-from-source"><img src="docs/badges/macos.svg" alt="macOS 14+" height="22"></a>
  <a href="Package.swift"><img src="docs/badges/swift.svg" alt="Swift 6" height="22"></a>
  <a href="LICENSE"><img src="docs/badges/license.svg" alt="Apache-2.0 license" height="22"></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a> · <a href="https://agenthud.app">Website</a> · <a href="#supported-agents">Supported agents</a> · <a href="#documentation">Documentation</a>
</p>

## At a glance, or a hover

<p align="center">
  <img src="docs/videos/simple-mode-tour.webp" alt="A tour of Simple mode on the left edge of a display. Five agent logos sit in quota rings, then show percentages and a balance. Hovering a logo writes that agent's quotas on one line, and a click opens Claude's card with its limits, burn rates and the 24-hour token bars. A permission request is answered with Allow once, a New reply reminder opens with Return to session, and the HUD is dragged to the top edge and back" width="800"><br>
  <sub><a href="#bots-modes-and-settings">Simple mode</a> on a display's left edge, with Separate agents on · Sample data</sub>
</p>

**A glance.** The glow shows one colour per quota, such as a 5-hour or weekly limit: green under 70% used, yellow from 70%, red from 90%. In Simple mode the ring around each logo does the same. The glow moves faster while an agent is working.

**A hover.** The panel opens with the numbers:

- **Quotas**: each one's share used and reset countdown, or its burn rate.
- **Balances**: account and prepaid balances, where an agent has them.
- **Tokens**: the last 24 hours in 15-minute bars.
- **Sessions**: up to five, those waiting for you first.

**A warning before a quota runs out.** It comes at 90% used, or sooner if the quota will not last until its reset.

## At the notch, and on every display

- **A MacBook with a notch**: Agent HUD lives at the notch.
- **A display without one**: it gets a HUD of its own, a row of agent logos you can drag to any screen edge.
- **Every display** keeps its own [mode](#bots-modes-and-settings), position, size and glow.
- **Requests and reminders** show on one display only: the one your pointer is on.

## Approvals, questions and replies in one place

When an agent needs you, its request waits on the HUD with the command, file, edit diff or tool input it is asking about. Answer there, without switching windows.

<p align="center">
  <img src="docs/screenshots/approvals.webp" alt="Four permission requests waiting at the notch. The first is open: an edit diff for Avatar.tsx, the line Always allow adds Edit(src/**), and the buttons Deny, Always allow and Allow once" width="720">
</p>

- **Approvals**: **Deny**, **Allow once**, or **Always allow** where the agent offers a rule.
- **Questions**: pick an option, or type your own.
- **Replies**: a **New reply** reminder when a turn finishes.
- **One click back**: a session's title, or **Return to session**, takes you to its thread, tab or iTerm2 pane.

**Agent HUD never answers for you**: a request you leave alone goes back to the agent's own prompt after 10 minutes. [Which agent supports what](#supported-agents).

## Where the tokens go

The statistics window keeps 30 days of token history on your Mac.

<p align="center">
  <a href="docs/screenshots/usage-statistics.webp"><img src="docs/screenshots/usage-statistics.webp" alt="The Tokens page of the statistics window: a stacked token chart with its total and cost at API prices, one card per agent with tokens by kind and cost, Recent usage with cost and cache hits for today, 7 days and 30 days, and an activity heatmap" width="468"></a> <a href="docs/screenshots/mac-session.webp"><img src="docs/screenshots/mac-session.webp" alt="A Claude Code session's page: 52M tokens with 6.0M from sub-agents, cost ≈$24.72 at API prices, 26 turns and 217 calls, context 66%, cache hits 99%, a tokens-per-turn chart with sub-agent parts faded, and turn 22 opened call by call" width="330"></a><br>
  <sub>The Tokens page and a session's page of the statistics window · Sample data</sub>
</p>

- **By time**: the last 5 hours, 24 hours, 7 days or 30 days, in bars as fine as 15 minutes.
- **By agent and model**: one card per agent, and a chart you can narrow to any models and token kinds.
- **By session, turn and call**: tokens per turn, how full the context window got, and every model call in a turn.
- **Sub-agents and cache**: sub-agent tokens inside their parent session; cache hit rates per period, session and model.
- **What it is worth**: priced at the vendor's API prices where a model has one, and marked ≈. On a subscription it is an estimate, not a charge.

## On your iPhone

Agent HUD for iPhone and Apple Watch shows what your Mac collects: quotas, balances, token statistics and sessions, in the app, in widgets and on the Watch. The app is free.

<p align="center">
  <a href="docs/screenshots/iphone-home.webp"><img src="docs/screenshots/iphone-home.webp" alt="Agent HUD on iPhone, Home tab: quota cards for Claude and Codex with the share used and reset time of each window, and a DeepSeek account balance" width="220"></a> <a href="docs/screenshots/iphone-sessions.webp"><img src="docs/screenshots/iphone-sessions.webp" alt="Agent HUD on iPhone, Sessions tab: today's tokens by kind with their cost, then sessions with per-turn bars and context-window fill" width="220"></a><br>
  <sub>Agent HUD for iPhone · Home and Sessions · Sample data</sub>
</p>

**On the same network, viewing is free.** In the [official Mac app](https://agenthud.app/mac), turn on Settings → Local network → **Share this Mac**. An iPhone on the same Apple Account connects by itself; any other iPhone pairs by scanning a QR code. The Mac serves the phone directly, with no Agent HUD server.

## Agent HUD Remote

**The one paid feature**, for when you are away from your Mac. It syncs through your own iCloud and adds:

- **Any network**: your Macs on iPhone, in widgets and on Apple Watch.
- **Conversations**: the prompts and replies of Claude Code, Codex, Grok CLI, Grok Bot and Antigravity sessions, to read on the phone.
- **Remote Sessions** (experimental; turn it on in the Mac's Settings → Experimental): allow or deny a tool call, and message Claude Code and Codex sessions, from the phone. See the [guide](https://agenthud.app/guides/remote-sessions).
- **Alerts and Live Activities**: alerts on iPhone and Apple Watch, and your running sessions on the Lock Screen and in the Dynamic Island.

The last three need Agent HUD Remote on the same network too. It is a subscription for 1, 2 or 3 Macs, monthly or yearly, with the first week free; iPhone and Apple Watch never count. Subscribe in the iPhone app, where the price is shown, then turn on Settings → Subscription → **Enable this Mac** on the Mac.

## Bots, modes and settings

**Bots.** Every agent's logo has a small bot in the logo's own shape and colours, with eyes that follow your pointer. It hops when the agent needs your approval and smiles when a turn is done. [See every agent's bot](docs/videos/agent-bots.gif).

**Modes.** Each display runs one of three: Notch by default where there is a notch, Dynamic elsewhere.

| Mode | On screen |
| --- | --- |
| **Notch** | At the notch, with the glow around it. |
| **Simple** | A small floating panel on any screen edge: each agent's logo in a ring of its most used quota, with the percentage beside it. |
| **Dynamic** | A row of agent logos on any screen edge, with the glow behind them. A logo becomes its bot while its agent works. |

**Settings.** Choose the accounts and quotas to show, each display's mode, size and glow, and what the panel contains. The app runs in English or Simplified Chinese. **⌘⌥H** hides or shows the glow.

## Supported agents

Install and sign in to the agents you want to monitor; Agent HUD finds them by itself. All 18 report tokens and sessions.

| Agent | Quota | Live status | Approvals | Questions | Replies | One click back | Turns and calls |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Claude&nbsp;Code** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Codex** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **DeepSeek&nbsp;Harness** | Balance | ✓ |  | ✓ | ✓ |  | ✓ |
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
| **Devin&nbsp;CLI** | ✓ (cached) | ✓ | ✓ |  | ✓ |  |  |

Devin's daily and weekly quotas come from its local CLI cache; refresh them in the CLI to update the readings.

Also: the **GLM Coding Plan** quota, and approvals for the **Qoder** builds. Codex approvals need its hook trusted in Codex, and Copilot's quota your consent in Settings. The rest is in [each agent's details](docs/providers.md).

## Your data

- **Read on your Mac**: the records your agents already keep. Usage history stays in a local database.
- **Read from each vendor**: quotas, balances and Cursor's usage, with the agent's existing sign-in or configured key. No read sends a message to a model, and credentials are never stored.
- **Written on your Mac**: hooks in your agents' own settings, to receive requests and replies. **Client hooks** in Settings → General removes them all.
- **Uploaded**: nothing, by a build from this source. What the official app shares with your iPhone, through your iCloud and for Live Activities is in its [privacy policy](https://agenthud.app/privacy).

See also [data access](docs/data-access.md).

## Build from source

**Requirements:** macOS 14+ and Xcode or the Xcode Command Line Tools with a Swift 6 toolchain.

```sh
git clone https://github.com/jazzenchen/agent-hud-native-open.git
cd agent-hud-native-open
make check
make test
make run
```

This builds and opens `build/Agent HUD Open.app`, signed ad-hoc for local use. No developer account, signing identity or provisioning profile is required. To try the app without any agents, quit it and run `make demo`, which opens it on sample data.

<details>
<summary><strong>Development and embedding</strong></summary>

| Command | Purpose |
| --- | --- |
| `make check` / `make test` | Check source boundaries / run unit tests |
| `make build` / `make run` | Build the locally signed app / build and open it |
| `make demo` / `make snapshot` | Open sample data / render the UI to `build/snapshots` |

The Swift package exposes `AgentHUDSupport` (records and identities), `AgentHUDCore` (providers, models and storage), and `AgentHUDDesktop` (native HUD and statistics). `AgentHUDOpen` is the standalone executable. Hosts can provide settings pages and services through `DesktopApplication`; see [host integration](docs/architecture.md#host-integration).

CI checks source boundaries, runs unit tests, builds the app and verifies its signature and resources.

</details>

## Documentation

[HUD and approvals](docs/hud.md) · [Providers](docs/providers.md) · [Usage semantics](docs/usage-semantics.md) · [Session lifecycle](docs/session-lifecycle.md) · [Session navigation](docs/session-navigation.md) · [Data access](docs/data-access.md) · [Architecture](docs/architecture.md) · [Performance](docs/performance.md) · [Command line](docs/command-line.md) · [Updates](docs/updates.md) · [Brand assets](docs/brand-assets.md) · [Changelog](CHANGELOG.md)

## License

[Apache-2.0](LICENSE). Provider references and icon assets retain their [third-party notices](THIRD_PARTY_NOTICES.txt) and [icon license](Sources/AgentHUDDesktop/Resources/LobeIcons-LICENSE.txt).

## Star History

<a href="https://www.star-history.com/?repos=jazzenchen%2Fagent-hud-native-open&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=jazzenchen/agent-hud-native-open&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=jazzenchen/agent-hud-native-open&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=jazzenchen/agent-hud-native-open&type=date&legend=top-left" />
 </picture>
</a>
