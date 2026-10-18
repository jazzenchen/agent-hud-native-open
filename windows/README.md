# Windows source port: Codex and Cursor

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
appearance setting change is needed. Open **Settings** from the tray, HUD right
click menu, or the panel's gear. Launching the Desktop shortcut again raises the
settings window of the existing instance. Hover opens the selected agent's
compact one-line quota peek in Simple mode (26pt at the default size), or a small
bubble in Dynamic mode. Click opens/pins that agent's full 440pt panel. Leaving
dismisses an unpinned peek. The full panel no longer opens merely from a hover.

## Windows platform boundary

The port keeps upstream Swift sources untouched. `source_design.py` reads their
palette, artwork and geometry constants. Platform-independent `placement.py`,
`glow_logic.py` and `look_logic.py` translate the original drag/offset, motion,
Gaussian fade and material-opacity rules. `runtime.py` handles presence and data
independently of views. Qt hosts the windows and paints the SwiftUI counterparts;
`material.py` is the Windows-only compositor boundary.

- Drag from anywhere on the collapsed HUD; release to snap to the nearest edge.
  The grabbed point remains anchored along the whole queue. Positions and display
  settings persist per monitor. Dragging a notch changes it to the logo dock, as
  upstream does. Click and drag use different paths, so dropping does not pin a panel.
- Settings follow the original General / Agents / Display / Experimental layout.
  General controls appearance, language, launch at login and reversible Cursor
  observers. Agents enable/disable reads and display for Codex/Cursor.
- Display supports Simple, logo dock and a 200pt stand-in notch (plus original
  flares), separate/combined agents, four edges, normalized position, light/dark
  HUD, acrylic style/opacity, size, ring/number visibility, quota/token/session
  blocks, panel width, session limit, hover/collapse timing and Alt gating.
- Dock/notch glow provides soft/dot/ASCII/block/Braille/binary renderers and the
  original breathe/flow/scan/ripple/shimmer/boot gain formulas. Simple has no glow.
  The overlay passes pointer input through. Grid controls are shown only for grid
  styles; range/feather for soft glow. Rendering uses Qt's primitives rather than
  Core Animation; this is a Windows counterpart, not pixel-identical compositing.
- Settings use source-style card rows, segmented selectors, switches and sliders.
  Window/menu appearance and each screen's HUD appearance are explicit separate
  scopes, following upstream. Themes update menus, statistics and already open
  HUD/peek/panel surfaces; light outlines/tracks use dark hairlines.
- `motion.py` supplies an exact damped spring and one shared clock that stops at
  rest. Interrupted panel/selector/switch transitions retain position and velocity.
  Decorative pointer lighting keeps controls/text stationary. Windows' client-area
  animation preference suppresses springs and continuous glow when disabled.
- The Acrylic adapter uses the explicit ABGR theme tint for every glass style;
  the legacy untinted Clear blur path was removed. Rounded native regions clip
  the compositor, and DWM's extra border is suppressed separately from Qt painting.
  See [UI_AUDIT.md](UI_AUDIT.md) for native evidence and remaining review gates.
- Acrylic replaces Apple Liquid Glass; Segoe UI / Microsoft YaHei UI replace
  Apple fonts. The Windows notch uses the source's fallback dimensions instead
  of claiming a physical camera notch exists.

Remaining gaps are explicit in Experimental: animated Bot direction, the MCP
draft/save host and approval bridge are not implemented. Historical statistics
are limited to the available cumulative session records, not the full Mac
statistics interface. English currently covers settings labels; notices and some
panel text remain Chinese. Other providers remain outside this Codex/Cursor port.
These are still draft-port limitations, not promises of full Mac feature parity.

## Source correspondence

| Upstream Swift source | Windows counterpart |
| --- | --- |
| `Notch/Simple/SimpleMeter.swift`, `SimpleMeterView.swift` | `views.SimpleMeterView`: tightest window, ring/mark/percentage, source size/insets/corner formula, no glow |
| `Notch/Panel/HoverPanelView.swift`, `HoverPanelView+Sessions.swift` | `views.HoverPanelView`: provider → tokens → sessions → footer, up to five session rows |
| `Notch/Panel/ProviderQuotaBlock.swift`, `ModelUsageRow.swift` | Provider headings, quota dots, used-percentage tracks, reset labels, source heading/label dimensions |
| `Theme/Theme+Palettes.swift`, `Theme/StatusPalette.swift` | `source_design.py` reads source palette and 70% / 90% status colors |
| `Components/AgentLogo.swift`, `Resources/{chatgpt,cursor}.png` | Original artwork; Codex's original #10a37f tint; Cursor's template tint |
| `PanelLayout/PanelLayout.swift`, `Models/Settings/ScreenPlacement.swift` | Original 540pt/440pt widths, 22pt size and 1.5pt ring stroke |
| `Notch/Island/IslandAnimation.swift` | Source transition timescale; the Windows shell uses a critically damped spring scaled to that duration for reversible morphs |
| `Notch/Panel/AgentPeekView.swift` | `peek_view.py`: one-line Simple peek, source 26pt/9pt baseline, scaled gaps/padding, Dynamic bubble; click opens full details |
| `Theme/HUDSurface.swift`, `JoinedGlass.swift` | `material.py`: Windows acrylic backdrop instead of Apple's compositor; source black-dimming semantics, a stand-in if unavailable |
| `Notch/NotchGeometry.swift`, `IslandShape.swift` | `placement.py`, `views.surface_path`: y-down edge/offset/grab conversion and fallback notch silhouette |
| `Notch/Glow/GlowMotion.swift`, `GlowMatrix.swift` | `glow_logic.py`: gain, noise, periods, flow sheen, Gaussian cutoff; `glow_view.py`: input-through Windows renderer |
| `Theme/HUDLook.swift`, `ScreenPlacement.swift` | `look_logic.py`: separate 0.6 cap for Solid/Clear/Regular and full material transparency |
| `Settings/SettingsView.swift`, `GeneralPane`, `SourcesPane`, `ScreensPane`, `GlowPane` | `settings_window.py`, `preferences.py`: source page structure, immediate persisted settings, per-screen model |
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
