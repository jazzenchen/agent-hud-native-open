# Windows parity audit

Reference: upstream source `bf19ac98da11fe0f5967f5a124d42f0da4bf2cf9`.
This is a release gate, **not a measured 90% similarity score**. A detected client
is not proof that its quota, approvals, completion and navigation work.

Latest checkpoint: account sections and DeepSeek API balances now render from
their separate observations. The local suite has 234 passing tests; 72 original
compiled Swift balance-spend cases also match. The native API surface matrix
passed 24 mode/edge/theme cases at 150% scaling. These are scoped checks, not a
whole-product similarity score. Remaining release gates below still apply.

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
| Display / Position, style reset/restore, own/shared layout/reset | Canonical source layout documents, shared/screen save/discard, two-way layout revert, reset and legacy scalar migration now connected. Source JSON verified against compiled Swift traces. | Whole-look style/app drafts and unified style/layout version history remain incomplete |
| Display / Separate agents | Working in Simple and Dynamic | Native multi-agent interaction audit still required after core changes |
| Display / Dynamic logo size, edge distance, gap, visibility | Working; no misleading notch-only logo controls | Original live preview missing for glow/dynamic settings |
| Display / Simple size, gap, rings, thickness, numbers | Working; thickness only shown while rings enabled, source 0.5pt step | Qt continuous-corner approximation is connected to fill/clip paths; Apple's private contour is not an exact cross-platform primitive |
| Display / Glow style/effect | All six styles and six effects; conditional source rows and period steps | Source preview and precise animation timing still require comparison |
| Display / Grid pitch/density/core/fade | Only grid styles; source ranges | UI percentage/row formatting still differs |
| Display / Brightness/range/feather/outward | Range/feather/outward only soft glow | Source preview absent |
| Display / Working/idle period, breathing depth | Periods apply to every effect; depth only breathing | Source percentage formatting differs |
| Display / Expanded panel: sessions/quota/countdown/tokens | Saved switches target the saved shared/own document and rebase only the changed draft field. Original Shared Layout reset/revert row is connected. Source 10-session cap and 440pt single-agent width floor apply. Fixed footer/draft bar stay outside scrolling content. | Inline samples, full session/token filters and ring/number/chart/half-block rendering remain incomplete |
| Display / Logo: Bot logos | Original generated bot assets and request kinds; independent staying reminder actors from 240 original source clips; news does not replace ongoing dock work | Pointer gaze, Clawd sprite variants and some loop transitions still differ |
| Display / Hover: Alt, immediate top edge, open/collapse delay | Native Windows behavior, same delay range/step | Option is intentionally mapped to Alt |
| Display / Menu bar icon | Tray icon and menu | Windows tray equivalent |
| Experimental / Let agents arrange the HUD; clients menu/copy settings | Layout normalization/documents, real draft Save/Discard controls and pure 120s hold state are implemented; external host is still disabled. | Five-tool transport/client setup, host hold scheduling, style/app drafts and complete renderer must be connected before enabling the setting |

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
| Quota metric selector / burn / forecast | Five real selections: quota, burn, reply rate, consumed, estimated cost. Source cycle sampling, last-hour/week reply horizon, bucket pricing, projected track and reported WorkBuddy consumption are connected. Native current-client consumer links preserve anonymous logs as local estimates without relabelling account history. External credential-pool/cross-client model links, all source widget types and native keyboard/accessibility controls still need parity. |
| WorkBuddy | Read-only source metering port: custom titles, session spending, context and model attribution. In addition, the installed desktop client's official billing-summary contract now supplies actual subscription name and remaining/total credits; separate enterprise metadata route and unlimited sentinel. No session spending is substituted for the account balance. Chinese SaaS gateway compatibility checked against installed 5.5.6; other deployments need separate adapters. |
| Quota / reset-credit alerts | Real threshold/reset/grant tracking and interactive reminder cards now connected. New readings only, silent startup/sign-in baseline, no fake reset from stale/error/unknown readings; forecast warnings once per cycle and actual exhaustion as a separate event. Four-second news lifetime, pointer hold, persistent permissions, callback-independent quota news and hidden-account suppression are implemented. Source staying reset bots are connected and captured natively. Inline-in-usage presentation and static exhausted-logo sign remain differences. Original warnings use a plain logo, not a warning bot. |
| Statistics | Channel/model/time filters and ledger exist; quota widgets, grouped account sections and DeepSeek API hover cards now render. Full API cards on the statistics window, exact token-chart interval/binning, richer sessions and external pool consumer links remain incomplete. |
| MCP layout editing | Original unchanged Swift schemas and layout documents compiled on macOS. Canonical normalization and 13 shared/screen transitions match the original trace; real keyboard-accessible draft bar, saved settings and disk-full rollback are connected. Native branch/row/account filtering and section order are applied without mutating readings. Quota and DeepSeek API widget rendering are connected. Transport, hold scheduling, style/app drafts and external billing-pool bindings remain incomplete. |
| White rims / black collapse trails | Native 24 mode/edge/theme matrix at 100%, 125%, 150% previously passed within documented tolerance; rerun after integration. Sampled frost is frozen while open. |
| Performance | Prior local paint measurements only; new end-to-end frame-time profiling not complete. An offline promo cannot prove live frame rate. |
| Promo / publication | 36-second Windows tour rendered from actual Windows widgets and original-exported actors, following the original tour structure. Account/credit/token examples are isolated and disclosed; original procedural wallpaper and synthesized music. Encoded 1080p/30fps/AAC file and 11 chapter/theme frames reviewed; manifests in `promo/`. Source preview publication and draft PR refresh are separate from the remaining stable-release gate and binary dependency-license review. |

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

## Current checkpoint

2026-10-19: 187 local Windows unit/integration tests passed. Source files under
`Sources/` remain byte-for-byte unchanged from the pinned original. Original
`main` was checked against GitHub and still matches that revision. The source
preview can be shared for review with the above gaps visible; this does **not**
establish a measured 90% score or stable-release readiness. Fork CI is checked
separately after pushing. No macOS or live-client pass is inferred from Windows
unit tests or the offline promo.

Layout checkpoint: 2026-10-19. `assets/upstream-layout-contract.json` and its
provenance were produced by original macOS QA run `39238385058`, commit
`85e610def9fb7d38c295925c0cf0b16780212dde`; the original `Sources/` tree was not
edited. Draft documents never persist. Save writes the whole saved profile
before advancing memory; a failed write retains the saved state, revision and
draft. A failed settings switch rebuilds from the saved value. Detached-screen
keys, unavailable block/row/account names and previous layouts survive.

This checkpoint also ports `Theme+Under.swift`'s relative secondary/tertiary/idle
ink tints. Fixed greys on light frost could coincide with a darker wallpaper;
the source black/white alpha tints now preserve their ordering. Draft surface
shape/morph tests covered 24 mode/edge/theme cases at each of 100%, 125% and
150%; final ink/glyph checks were repeated on selected native cases. These are
scoped visual/interaction checks, not an overall similarity measurement.
The current local suite has 208 passing tests; native check scope is recorded
in `assets/layout-native-checkpoint.json`, including the timing of the relative
ink correction. The resident Windows instance was restarted and reports active
layout documents with only the currently running Codex visible.

Layout planning checkpoint: the Windows planner matches all 144 plans exported
by the original compiled Swift core, plus 30 grid width/fitting cases. These
cover half-block fallback, spacing, widget/measure constraints, filters and
columns. Export provenance is in `assets/upstream-plan-provenance.json`.
The planner is now connected to quota rings, numbers, charts and half-block
pairing. These contract checks do not establish visual similarity.

Quota widget checkpoint: native rings retain the used share under every measure,
with the source sizes, projected arc, complete/wrapped names and reserved caption
line. Numbers use a short figure candidate; chart stacks read indexed local model
buckets over day/week/month, not generated account history. Grid partial lines
centre as in the source. Separate-agent panels stay single-block; grouped panels
pair adjacent half blocks only when the source width threshold fits. Picker
identity resets on widget/measure-list changes. Layout row keys apply across
accounts while Settings visibility keys remain account-specific.

There are 217 passing local tests at this checkpoint. Twenty-four native fixture
captures cover two themes, six widget arrangements and 100%/150% scaling, with
representative visual review; exact scope and warm synchronous repaint timings
are in `assets/layout-widgets-native-checkpoint.json`. Those timings are not a
resident animation benchmark. Remaining widget work includes API billing blocks,
complete multi-account subheaders, credential-pool consumer links, original chart
inspection/transition behavior and painted-cell keyboard/accessibility parity.
Full session/token/HUD filtering, MCP transport and hold scheduling remain open.

Account/API checkpoint: quota rows now split by account in first-row order,
including independent ring/number grids, retained-reading opacity, source-style
header read age, notices and account wallets. A layout's row order stays within
each account. Current WorkBuddy credits never spill into a retained account;
wallet money preserves cents and distinguishes reported zero from an absent
limit. Account filters also narrow wallets. The peek keeps current accounts only
and de-duplicates their short names.

DeepSeek now uses `api:DeepSeek` layout blocks, never a subscription percentage.
Its first currency also appears on Simple and peek views, with the account's
lowest balance level and an empty ring. Hidden billing accounts cannot reappear
through a legacy fallback. Failed reads retain actual money without a level.
Valid unavailable/negative official balances no longer disappear as parse errors.
The source-style number/chart cards share measure selection; half cards stack
columns when needed and keep their height across measures.

The worker prices only observed official-Harness requests. A small additive
ledger table retains the official-provider marker and request start for source
peak pricing, without altering token history. Old unverified events stay
unpriced until observed again; anonymous records never acquire an identified
account. Missing prices poison the affected currency, not silently undercount it.
Separate CNY/USD catalog prices are used, without currency conversion. The
compiled-original balance contract/provenance records 72 cost, pace and run-out
cases, including overlapping buckets and partial periods.

Native fixtures: 32 full-background captures span eight account/API arrangements,
two themes and 100%/150% scaling, plus 24-case quota and API surface matrices at
150%. Warm repaint figures are scoped in `assets/account-billing-native-checkpoint.json`.
The layout capture helper previously failed to override its backdrop's fixed
size; older widget captures could include unrelated background windows. Those
background samples are superseded by this corrected full-screen fixture run.
They were never evidence of compositor parity. The separate surface-audit
runner already used a full-screen backdrop; it now exits unsuccessfully if its
checks find a failure.

Still open: full statistics-window API cards, external account/pool consumer
bindings, earned-reset rows, complete account-source assessment/accessibility,
chart inspection/transitions and exact token-chart time bins. No overall 90%
claim or stable binary release follows from these checks.
