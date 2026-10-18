# Windows source port: Simple HUD, Codex and Cursor

Windows counterpart of the upstream **SimpleMeterView** and its separate-agent
hover panels. Defaults: **Simple mode · frosted material · separate agents**.
Only running clients appear. Merely having a database or being signed in never
causes an agent to appear or its engine to start. Opening Cursor adds its meter;
closing Cursor removes its meter, panel and cached account display within a poll.
No active clients means no HUD windows; the tray remains available to quit.

The SwiftUI/AppKit app cannot execute unchanged on Windows. The Windows host uses
Qt/PySide6 to translate the selected SwiftUI views, while reading the original
Swift source's design constants and original bundled artwork. This is a source
port of the scoped views, **not a claim that SwiftUI compiles on Windows**, nor
parity with all providers, charts, approvals, MCP Host API and Mac settings.

## Install

Python 3.10+ and an Internet connection for first installation are required.
Keep the full checkout (including `Sources/`) in place.

```powershell
cd windows
.\install.ps1
# Optional login startup: .\install.ps1 -Startup
# Without Cursor activity observers: .\install.ps1 -NoCursorHooks
```

The installer creates an isolated `.venv`, installs Qt Essentials and psutil,
preserves unrelated Cursor hooks, replaces only this checkout's running HUD, and
updates the Desktop shortcut. No administrator rights, client launch or Windows
appearance setting change is needed. A tray menu changes the frosted material
and HUD size; 22pt is the original source default. Hover opens that agent's own
440pt panel; click pins/unpins it; leaving dismisses an unpinned panel.

## Source correspondence

| Upstream Swift source | Windows counterpart |
| --- | --- |
| `Notch/Simple/SimpleMeter.swift`, `SimpleMeterView.swift` | `views.SimpleMeterView`: tightest window, ring/mark/percentage, source size/insets/corner formula, no glow |
| `Notch/Panel/HoverPanelView.swift`, `HoverPanelView+Sessions.swift` | `views.HoverPanelView`: provider → tokens → sessions → footer, up to five session rows |
| `Notch/Panel/ProviderQuotaBlock.swift`, `ModelUsageRow.swift` | Provider headings, quota dots, used-percentage tracks, reset labels, source heading/label dimensions |
| `Theme/Theme+Palettes.swift`, `Theme/StatusPalette.swift` | `source_design.py` reads source palette and 70% / 90% status colors |
| `Components/AgentLogo.swift`, `Resources/{chatgpt,cursor}.png` | Original artwork; Codex's original #10a37f tint; Cursor's template tint |
| `PanelLayout/PanelLayout.swift`, `Models/Settings/ScreenPlacement.swift` | Original 540pt/440pt widths, 22pt size and 1.5pt ring stroke |
| `Notch/Island/IslandAnimation.swift` | Original 400ms transition and cubic curve (0.2, 0.8, 0.2, 1) |
| `Theme/HUDSurface.swift`, `JoinedGlass.swift` | `material.py`: Windows acrylic backdrop instead of Apple's compositor; source black-dimming semantics, a stand-in if unavailable |
| `Font+UI.swift` | Windows system font (Segoe UI) in place of Apple's SF Pro |

Desktop paths in this table are relative to `Sources/AgentHUDDesktop`; core
settings/layout paths to `Sources/AgentHUDCore`. Source contracts are tested and
fail explicitly if the required constants change upstream. No Swift file changes.

### Data scope

- **Codex**: read-only nonarchived session metadata, bounded rollout tails, explicit
  lifecycle events, cumulative per-session tokens, and live
  `account/rateLimits/read` through the installed app-server. The probe never
  starts a model turn and never counts as an open Codex client.
- **Cursor**: read-only composer metadata, new-turn prompt/stop observers, and
  the existing account's `https://cursor.com/api/usage-summary`. An expired
  login requires signing in again in Cursor; no login refresh is attempted.
- Presence polls every 2 seconds. Closed clients' records are not read and their
  quota engines are not launched. Stale asynchronous results are discarded.
- The token chart shows **each recent session's cumulative count**, not a fake
  24-hour chart or a sum of potentially inherited parent/child counters. Missing
  data stays unavailable. Last seen does not claim completion.
- Credentials remain in memory. No prompts, replies, commands or credentials are
  persisted. SQLite includes committed WAL records and stays read-only.
- Activity/config/health metadata lives in `%LOCALAPPDATA%/AgentHUDOpen`.

## Verify / remove

```powershell
# From repository root, after installation
windows/.venv/Scripts/python.exe -m unittest discover -s windows -p "test_*.py" -v
windows/.venv/Scripts/python.exe windows/hud.py --probe
windows/.venv/Scripts/python.exe windows/hud.py --preview-dir windows/previews
windows/.venv/Scripts/python.exe windows/install_hooks.py --remove
```

Previews use explicit fixture data, never account readings. The tests cover the
source design contract, separated views, process gating, ignored probes/servers,
closed-client races, read-only WAL, parser lifecycle, missing quota and reversible
observers. Real Cursor-emitted observer delivery and signed-in Cursor quota need
manual acceptance with a current client login. Acrylic depends on Windows/DWM;
the fallback remains readable and does not change system security settings.

Cursor observers are backed up alongside `~/.cursor/hooks.json`. The prompt hook
returns `{"continue":true}`; stop returns `{}`; neither changes tool approvals or
adds follow-up prompts. Remove them with the command above, quit from the tray,
then remove the Desktop/Startup shortcuts. Client data and other hooks remain.

Repository Apache-2.0 and artwork notices still apply. See
[THIRD_PARTY.md](THIRD_PARTY.md) for the dynamically installed Windows runtime.
