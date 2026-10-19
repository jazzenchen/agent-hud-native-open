# Windows parity audit

Reference: upstream source `bf19ac98da11fe0f5967f5a124d42f0da4bf2cf9`.
This is a release gate, **not a measured 90% similarity score**. A detected client
is not proof that its quota, approvals, completion and navigation work.

## Settings list and behavior

| Upstream section / rows | Windows implementation | Remaining difference |
| --- | --- | --- |
| General / Appearance, Match screen | Persisted, light/dark/system, per-screen window styling | Sampled backdrop differs from live macOS material |
| General / Language: System, Chinese, English | Choices persist; primary settings labels translate | System language resolution and complete app-wide English coverage incomplete |
| General / Launch at login | Windows Startup shortcut | Windows equivalent of login item; shortcut must already exist |
| General / Client hooks | Reversible, preserves foreign hooks; real named-pipe approval and reply transport | Source coverage below; removal disclosure/confirmation still differs |
| General / Wait for an answer | Exact source choices 1/3/5/10/30/60 minutes; active deadlines refresh; expiry returns to client | None identified in translated protocol; live client compatibility remains separate evidence |
| Agents / provider inventory, passive discovery, drag order | Original catalog read from source; installed and running separated | Qoder variants share original provider grouping; dedicated approval-only identities need explicit integration |
| Agents / Accounts, plan, visibility, refresh | Real account metadata, separate account visibility, history preserved | Original account-card layout/current-observation badges and historical-account visibility still differ |
| Agents / Visible windows, drag and visibility | Account-scoped stable IDs, separate account lists; legacy choices migrate; other account slots remain fixed | Visual samples still need comparison |
| Agents / Sessions & reminders: Live status | Separate from collection and history; disabled sources cannot queue old replies for replay | Source-specific runtime observers still incomplete |
| Agents / Agent client list | Installed/running status backed by passive evidence | Grouping and client details not fully equal to source |
| Agents / Client readings | Copilot quota consent works | Pi/OpenCode observer file ownership, version and last-report rows not ported |
| Display / Screens, HUD mode, appearance, material, transparency | Per-screen settings, all three modes; separate solid/glass opacity | macOS Clear/Regular materials use a bounded sampled-frost approximation |
| Display / Position, style reset/restore, own/shared layout/reset | Persisted, reachable-screen clamp, shared-layout restore | Layout editing schema not yet complete |
| Display / Separate agents | Working in Simple and Dynamic | Native multi-agent interaction audit still required after core changes |
| Display / Dynamic logo size, edge distance, gap, visibility | Working; no misleading notch-only logo controls | Original live preview missing for glow/dynamic settings |
| Display / Simple size, gap, rings, thickness, numbers | Working; thickness only shown while rings enabled, source 0.5pt step | Continuous-curvature corners still pending |
| Display / Glow style/effect | All six styles and six effects; conditional source rows and period steps | Source preview and precise animation timing still require comparison |
| Display / Grid pitch/density/core/fade | Only grid styles; source ranges | UI percentage/row formatting still differs |
| Display / Brightness/range/feather/outward | Range/feather/outward only soft glow | Source preview absent |
| Display / Working/idle period, breathing depth | Periods apply to every effect; depth only breathing | Source percentage formatting differs |
| Display / Expanded panel: sessions/quota/countdown/tokens | Working switches and preserved per-screen layout | Original inline samples and richer block/widget layout missing |
| Display / Logo: Bot logos | Original generated bot assets, asking/done states from real events | Pointer gaze, variants and some loop transitions still differ |
| Display / Hover: Alt, immediate top edge, open/collapse delay | Native Windows behavior, same delay range/step | Option is intentionally mapped to Alt |
| Display / Menu bar icon | Tray icon and menu | Windows tray equivalent |
| Experimental / Let agents arrange the HUD; clients menu/copy settings | **Not implemented** | Must port draft/save/discard/hold semantics and real client setup; no fake enabled control |

Source pages: `Sources/AgentHUDDesktop/Settings/{GeneralPane,SourcesPane,ScreensPane,GlowPane,IslandPane,DisplayPane,ExperimentalPane}.swift`.

## Core functionality beyond settings

| Capability | Current evidence / gap |
| --- | --- |
| Real permission decision | Current-user named pipe → actual painted card → mouse release → client stdout. No approval on hover, press, timeout or unknown input. Inputs/replies remain in memory. |
| Codex automatic review boundary | Exact newest matching turn reviewer must be `user`; unknown/guardian contexts fall through to client. No trust bypass. |
| Claude questions/plans | Actual answer and plan decision wire, explicit accept-edits option; unsupported clients retain their own dialog. Inline source visual layout still differs. |
| Cancellation / no HUD / malformed input | Fall through, bounded framing and startup read, client disconnect withdraws pending card; future matching Claude transcript result also settles it. |
| Hooks installed in existing homes | Claude, Codex, WorkBuddy, CodeBuddy, Qwen, ZCode, Devin. Qwen timeout units and ZCode nested events follow original source. Cursor has its separate actual stop schema. |
| Remaining original approvals | Qoder variants, Antigravity native service, DeepSeek Harness web question channel need porting. These are **not macOS-only exclusions**. |
| Completion reminders | Hook/log transition transport for supported mappings; stable WorkBuddy/CodeBuddy message identity and Qwen/Devin prompt ID. No historical startup backfill. |
| Remaining completion/status channels | Antigravity/Copilot hooks and Pi/OpenCode observers need parity. Local session parsing alone is insufficient evidence. |
| Return to session | Codex registered URI; Claude native executable resume when available; strict ID validation. Installed-handler dispatch is not proof that every target client version opens the intended session. |
| Quota metric selector / burn / forecast | Missing source picker and historical-rate calculation; a percentage alone is not parity. |
| WorkBuddy | Read-only source metering port: custom titles, session spending, context and model attribution. In addition, the installed desktop client's official billing-summary contract now supplies actual subscription name and remaining/total credits; separate enterprise metadata route and unlimited sentinel. No session spending is substituted for the account balance. Chinese SaaS gateway compatibility checked against installed 5.5.6; other deployments need separate adapters. |
| Quota / reset-credit alerts | Source has threshold-crossing alerts, acknowledgement/dedup policy and reset-credit expiry grants. Windows colors alone do not reproduce these alerts; policy and actual reminder cards still need porting. |
| Statistics | Channel/model/time filters and ledger exist; original richer sessions and multi-block layout incomplete. |
| MCP layout editing | Original unchanged Swift compiled on macOS; exported exact five-tool schemas at `assets/upstream-mcp-contract.json`. Windows runtime/draft UX still missing. |
| White rims / black collapse trails | Native 24 mode/edge/theme matrix at 100%, 125%, 150% previously passed within documented tolerance; rerun after integration. Sampled frost is frozen while open. |
| Performance | Prior local paint measurements only; new end-to-end frame-time profiling not complete. An offline promo cannot prove live frame rate. |
| Promo / publication | Original tour structure inspected; actual-app recording, review, complete attribution/package license audit and upstream PR update still pending. |

## Genuine platform adaptations

macOS login items → Windows Startup; menu bar → tray; Option → Alt;
Unix sockets → current-user Windows named pipes; Keychain reads → supported
Windows credential sources; physical notch geometry → source's no-notch stand-in.
AppKit/SwiftUI live materials cannot simply be enabled on Windows. Their visual
approximation must be disclosed and tested. Approvals, MCP, usage, statistics,
reminders and account detection are **cross-platform product features**, not
items to remove as “Mac only.”

## Export provenance

`assets/upstream-mcp-contract.json` was generated by compiling unchanged original
MCP definitions in fork QA commit `6633b9444e228b940163d7c9479dfd4e0a896f82`.
GitHub Actions run `39223404514`, artifact `original-source-contract`.
SHA-256: `9047484fb73cb94e16b8519ae9b3bcdca63ea6518bfc43e788eca8e16ba7186e`.
Original names, schemas, descriptions and protocol revisions are retained for
translation and contract tests. Windows transport must describe its own platform
honestly rather than copy the source's Mac-specific handshake text.
