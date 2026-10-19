# Windows source port

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
The source-by-source release gate, including unfinished cross-platform core
features, is tracked in [PARITY_AUDIT.md](PARITY_AUDIT.md).

## Permissions and replies

Client hooks now bridge to a current-user Windows named pipe. The actual HUD
card can allow or deny supported tool requests, answer Claude/ZCode questions,
review Claude plans, and display successful new replies. Codex requests are
held only when the newest matching turn explicitly names the user as reviewer;
automatic review and unknown contexts remain with Codex. Installing a hook never
bypasses Codex's own `/hooks` trust confirmation.

Claude, Codex, WorkBuddy, CodeBuddy, Qwen, ZCode and Devin use their original
source-specific settings layouts; Cursor retains its separate stop callback.
Unknown layouts are refused. Unrelated hooks are preserved and changed files
are backed up. Turning callbacks off removes this port's entries. Cancellation,
disconnection and expiry give no approval. General's source-derived wait choices
apply to pending requests. Turning Live status off suppresses session-state
display and replies while keeping usage collection and history intact.

Session return is offered only where the actual platform can address that
session (registered Codex URI, installed native Claude resume command). Failed
navigation retains the reminder. WorkBuddy's database is opened read-only for
custom session titles and charged session credits, including unattributed
amounts and context size. Charged credits are never presented as remaining
subscription credits.

WorkBuddy's Chinese desktop account also uses the official billing-summary
metadata endpoint for its subscription name and remaining/total credits, with
the client's current signed-in account read from its existing auth file. This
adapter follows the installed 5.5.6 request/header contract; no proprietary app
code is redistributed. It makes no model call, login refresh, purchase or
check-in. Credentials stay in memory and the HTTPS origin is fixed; redirects
are refused. An expired/missing/unsupported protected login asks for sign-in in
WorkBuddy. An account switch during a read discards that result. Optional GLM
plan windows stay separate from the official WorkBuddy subscription and balance.

Quota readings now drive actual warnings, confirmed resets and new Codex usage
reset grants. The first reading is a silent baseline. Provider errors, expired
reset deadlines, future/old observations and account switches do not invent
events. A quota worker stores observed samples per opaque account/window and
uses upstream's cycle-aligned sampling and burn-rate math. No consumption is
simulated between readings. A forecast is unavailable without a known cycle and
sufficient observed span.

News, including completed replies, expires four seconds after presentation or
the pointer last leaves; hovering holds it. Requests remain until answered,
withdrawn or the configured client wait expires. Quota news cannot displace a
waiting permission. Disabling client hooks leaves quota reminders available;
Live status controls replies separately. Closing clients or hiding an account
or window prevents old news being replayed when it returns. The expiry clock
stops once news drains. The full release-gap list remains in PARITY_AUDIT.md.

## Install

Python 3.10+ and an Internet connection for first installation are required.
DeepSeek compressed logs and its original balance helper require Node.js 24+ with zstd support.
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
bubble in Dynamic mode. Click opens that agent's full 440pt panel. It closes after the pointer leaves the HUD/peek/details region, without another
click. It also closes when another window takes focus, including settings. With Separate agents off, hover opens the shared
panel instead. Separation scopes the hover; the agents retain one source-shaped
strip rather than being split into separate capsules.

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
  observers. Agents lists all 18 upstream detection groups with original artwork,
  passive Windows install/process discovery and a detail column. Discovery does
  not start clients or claim authentication. All 18 groups have data adapters and display switches: 17
  have local or account Token records, while GLM represents its official plan
  quotas. DeepSeek, Antigravity, Grok and GitHub Copilot use source-format readers
  and original metadata routes. Copilot quota retains the original explicit opt-in.
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
- Frost and themed dimming use one Qt shape mask. Windows Accent blur ignores
  the silhouette of layered windows on the tested machine and left rectangular
  corner tint and collapse trails. These surfaces therefore sample a bounded
  desktop backdrop into memory before opening and blur it in Qt. That snapshot
  stays fixed throughout the morph; details/peeks refresh on reopening, while
  the collapsed strip refreshes when shown or moved outside its cached strip.
  It does **not** continuously follow windows moving behind the HUD. No backdrop
  images are written to disk, and closed surfaces release their snapshots.
  DWM's extra frame is suppressed; Qt alone owns the physical mask, avoiding a
  second native radius that disagreed at fractional display scales.
  See [UI_AUDIT.md](UI_AUDIT.md) for native evidence and remaining review gates.
- Sampled Windows frost replaces Apple Liquid Glass; Segoe UI / Microsoft YaHei UI replace
  Apple fonts. The Windows notch uses the source's fallback dimensions instead
  of claiming a physical camera notch exists.

Bot figures now play original-source frames in both HUD modes and themes.
The MCP draft/save host and approval bridge remain unimplemented. Historical statistics
now use request-keyed SQLite events, model totals and 15-minute buckets;
this still does not reproduce the full Mac statistics interface. English currently covers settings labels; notices and some
panel text remain Chinese. WorkBuddy credits/context
meters, cross-client plan attribution and multi-home account discovery still
need further source ports and signed-in acceptance.
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
| `Notch/Island/IslandAnimation.swift` | Original 0.4s cubic timing curve (0.2, 0.8, 0.2, 1); interrupted morphs preserve velocity |
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
- The token chart uses request-keyed, 15-minute ledger buckets for the last
  24 hours. Missing data stays unavailable. Last seen does not claim completion.
- Credentials remain in memory. No prompts, replies, commands or credentials are
  persisted. SQLite includes committed WAL records and stays read-only.
- Activity/config/health metadata lives in `%LOCALAPPDATA%/AgentHUDOpen`.
- Failed quota reads keep the last successful values marked as stale. Transient
  failures retry after 15/30/60/120/180 seconds; login failures back off for two
  minutes. The tray's Refresh quota action requests another read. Loading and
  accounts without percentages are distinct from failures. Health metadata
  records error categories and last-success times without raw exception text.
- If configuration cannot be written, the previous configuration is retained
  and display-setting changes roll back. Full-disk health writes do not interrupt
  the HUD. See [UI_AUDIT.md](UI_AUDIT.md) for collected failure cases and evidence.

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
manual acceptance with a current client login. If desktop capture is unavailable,
the themed stand-in remains readable and does not change system security settings.

Cursor observers are backed up alongside `~/.cursor/hooks.json`. The prompt hook
returns `{"continue":true}`; stop returns `{}`; neither changes tool approvals or
adds follow-up prompts. Remove them with the command above, quit from the tray,
then remove the Desktop/Startup shortcuts. Client data and other hooks remain.

Repository Apache-2.0 and artwork notices still apply. See
[THIRD_PARTY.md](THIRD_PARTY.md) for the dynamically installed Windows runtime.


## Account and Token adapters

Codex reads account identity and limits from the same app-server process, with
an optional account/read reply; an unsupported identity method does not erase
valid limits. Cursor confirms the local session by the accepted official usage
request, exposes all six upstream quota pools and reads paginated billing Token
events. Claude uses only the original get_usage control request with hooks
disabled, without submitting a user message. Kimi, GLM and OpenCode Go use the
original official metadata routes; WorkBuddy GLM plan entries are scoped to
that group. Custom endpoints never fall back to an assumed official host.
Credential scopes stay separate unless a provider-owned identity confirms they
share an account. Cached history is distinguished from current sign-in.

Local Token readers cover Claude, Codex, CodeBuddy, WorkBuddy, OpenClaw, Pi,
Qwen, Kimi, OpenCode, Hermes, ZCode, Devin, DeepSeek, Antigravity, Grok and
GitHub Copilot. Counts are keyed by request identity
(or the source's usage row), preventing refresh/restart/stream duplicates;
Codex forks consume inherited baselines without counting the parent's history.
Input includes cache writes and output includes reasoning; display channels
subtract those subsets before stacking. Unknown historical account ownership
stays unknown. No conversation bodies or credentials are saved in the ledger.
Initial indexing is incremental and explicitly labeled incomplete. Closed or
disabled clients are never polled; no client is launched for detection.

Windows paths and source-format fixtures have local regression coverage. Only
Codex's current signed-in account and real Token indexing have been verified
on this machine. At the user's direction, the other providers are accepted at
code/fixture level: no login or real-client launch was performed for them.


## Original Bot animation source

The bundled animation atlases are rendered by the unchanged original
`BotMotion`, `BotRenderer`, `BotSpec` and `BotForm` at upstream revision
`bf19ac98da11fe0f5967f5a124d42f0da4bf2cf9`. Windows plays their 24 fps frames,
pose and opacity; it does not redraw lookalike characters. `WindowsBotExportTests.swift`
is the reproducible export harness for macOS, and `pack_bot_assets.py` packs its
output into lossless, sRGB-preserving PNG atlases with temporal locality.
`assets/bots/provenance.json` records every output hash. The pack is about 22 MB,
loads only selected clips, and uses bounded image/page caches.

The setting **Display → Logos → Bot logos** follows the original default. Real
session states select the animation: work/thinking/tools, waits, hover, or an idle
visit. A full percentage does not invent a limit-hit event. Source fallback Clawd
is used instead of copying new game sprite assets. Continuous pointer-directed
gaze and every original sprite/event variant remain acceptance gaps.

Clicking details does not make them permanent: leaving HUD/peek/details starts
the configured collapse delay; entering details cancels it. Window deactivation
also dismisses details. Account visibility and per-window drag order persist,
change only quota/wallet presentation, and never erase recorded usage.
## Quota measures

Each provider heading has the original five measure choices: quota, burn rate,
reply rate, consumed amount and estimated list cost. Choices survive reading
refreshes independently per provider. Derived statistics run on the monitor
worker with bounded read-only ledger queries; a failure leaves live quota intact.
Reply rate uses same-session call gaps up to 120 seconds, the latest hour first
and the previous week when the hour has no usable pair. Consumed/cost figures
use only the observed part of a known cycle. Native local logs remain local
estimates, with a tooltip; no anonymous event acquires an account identity.
Known foreign-account records do not join the current account's readings.

`assets/upstream-pricing-contract.json` exports the unchanged original catalog,
including exact aliases and service routes, checked by upstream on 2026-09-25.
Summed usage uses its base prices, exclusive token kinds and applicable currency
and peak-hour rules; it never treats a bucket as one long prompt or converts
currencies. Unknown models/routes have no invented price. Estimates are not bills.
External plan-pool consumer links and the original widget/layout variants remain
incomplete; see the release gate in `PARITY_AUDIT.md`.

## Promo samples

`promo_fixtures.build_demo(now, elapsed)` is an explicit offline recording input
for Codex, Claude, Cursor and WorkBuddy. It supplies fictional Token history and
sessions with internally consistent totals. A recorder must show its disclosure
(`演示数据 · Demo data`). The resident application never loads this module; it
does not modify account readings, client logs or the usage ledger.
