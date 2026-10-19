# UI audit — 2026-10-19

This records the local Windows implementation and evidence. It does not assert
90% visual similarity, upstream approval, or feature parity. The existing PR is
still a draft; this iteration is not pushed to that PR or published as a release
without satisfying the user's visual acceptance gate.

## Corrected paths

- Simple hover now uses the original AgentPeek hierarchy: one quota line, 26pt
  high at default size, 9pt baseline text, measured label/value widths and source
  padding/gaps. Click opens the full details. Dynamic hover uses the small bubble.
- Source application name, icon and version identify settings. No personal,
  Windows-only or Codex/Cursor-only branding is shown. The repository homepage
  introduction was restored; platform documentation remains under windows/.
- Settings use source page structure, 212pt sidebar, 640pt content, cards,
  segmented selection, compact switches and numeric sliders. Rebuilding options
  restores scroll positions. Main actions retain native keyboard semantics.
- A common resolver covers light/dark/system window themes and independent
  per-screen HUD themes. Existing panel and peek materials update as settings
  change. Statistics and menus no longer hardcode dark. Popup menus rebuild from
  current data and retain explicit ownership of provider submenus.
- Light text, logo tint, rings, separators, tracks and borders use light-theme
  tokens. Native untinted blur and an independent source dimming layer now
  replace the earlier Acrylic tint, including Clear/Regular fallback. Both Qt and
  native window regions are rounded; the additional DWM border is disabled.
- Panels morph from their actual source bounds; their content keeps a fixed
  layout during expansion. Springs preserve current value and velocity under
  reversal. Switch press compression and restrained card lighting do not move
  hit boxes. Springs sleep at rest; reduced motion disables continuous effects.
- Also corrected: top-edge opening only triggers at the actual screen edge;
  pressing Alt while already hovering works; reset labels show real countdowns;
  settings writes replace an atomic temporary file.

## Verification

105 tests pass locally, including real control clicks through persistence and
rendered-pixel checks for window/HUD/panel/peek light/dark changes. Regressions
cover live menu dispatch, click versus drag, compact hover versus click-to-pin,
rapid reversal, stable spring integration, reduced motion, and canceled/keyboard
switch activation. Existing data/presence/hook checks remain in the suite.
Style reset also persists glass/glow defaults while preserving panel layout.
A newly started spring no longer inherits time spent on an earlier animation
while the UI was busy rebuilding; a regression covers that first-frame jump.

## Further source comparison and acceptance status

The unchanged upstream HUD reference build also completed successfully in
[run 39193519954](https://github.com/nanhudev/agent-hud-open/actions/runs/39193519954).
Its artifact includes the Simple size/ring/number/side-edge contact sheet and
dark/light/glass dock and hover fixtures. These snapshots use the upstream glass
stand-in; they are not captures of Apple's live Liquid Glass.

Further corrections from this comparison:

- Translate all SimpleMeterConfig insets, mark/ring visibility, numberless gaps,
  vertical number columns and corner calculations. Ringless marks no longer
  retain the full ring's size or its padding.
- Separate agents scopes hover to the selected provider in a single strip,
  rather than splitting that strip into unrelated capsules. With separation off,
  hover opens the shared panel and shows all present providers. Pinned content
  keeps its scope when the pointer crosses a different mark.
- Cancel pending hover timers when hiding a client; dismiss incompatible popups
  on mode changes. Scale Dynamic bubble rows/title as well as its window. Clamp
  long session panels to the display and allow wheel scrolling.
- Read full-card 22pt and bubble 14pt radii directly from ScreenHUD.swift. Read
  light-HUD fill/text and glass text shades from StatusPalette.swift separately.
- Restore all 18 source-detection groups from the upstream catalog, original
  artwork and the SourcesPane list/detail layout. Passive Windows path/command/
  process detection refreshes while settings is visible; it never starts clients.
  Fourteen groups now have data adapters; DeepSeek, Antigravity, Grok and
  GitHub Copilot remain detection-only, without nonfunctional controls.
- Restore persisted, bounded per-screen versions: style reset, layout reset and
  use-shared can be reverted after restart. Glass and Solid retain separate
  transparency values; old saved values migrate without being discarded.
- Compact segment metrics, selected tint, numeric slider labels, disabled
  buttons and settings section spacing now follow the source more closely.
  Per-quota-window visibility leaves the original readings intact.

Native 125% and 150% scale probes both captured dark/light scenes and successful
Acrylic calls. Earlier Acrylic probes exposed a blocker: Acrylic's
outer backdrop can remain a rectangle with the OS's small corners even though
Qt paint and GetWindowRgn report the intended capsule. A new outside-capsule
pixel check compares the surface against the same owned wallpaper before the
overlay exists; on the light 100% sample its meter/peek deltas were 142/138 RGB
levels (threshold 16), so both failed. Native region success alone is no longer
accepted as proof that the visible material is clipped correctly. Tests with no
OS rounding, an opaque Qt host, the legacy DWM blur region and removing the
layered style did not fix it and were not adopted.

Current PR gate: **FAIL / below verified acceptance**, with no invented numeric
score. Remaining differences include per-window drag ordering, complete English,
full historical statistics layouts and other unported interfaces. The four CLI/data
adapters and sampled corner residual described below were corrected in the latest
iteration; see the final dated acceptance section.
The Windows PR branch has not been pushed with these changes. Source-geometry
checks passing, a successful capture, or large matching background areas cannot
establish overall 90% similarity.

## Additional bad cases collected and corrected

| Case | Correction and evidence |
| --- | --- |
| One failed quota read erased usable values for three minutes | Keep the last successful reading with an explicit stale label; retry after 15/30/60/120/180 seconds from failure completion, reset on recovery. |
| Loading, missing percentages, expired login and network failure all looked unavailable | Distinct safe states in meter tooltips, peek tooltips, full panel and tray; manual Refresh quota action. Unknown exception strings are never copied to UI or diagnostics. |
| Authentication and network failures had the same Codex message | Classify auth/network/throttle responses; timeout, storage and disk-full categories are explicit. |
| Legacy quota fallback disagreed with CodexRateLimits.buckets | A present empty map is authoritative, as in the original source. Only a missing map falls back; zero is valid, null/nonfinite values are skipped. |
| Full disk broke health writes or left settings changed only in memory | Health-write failures no longer escape the UI callback; configuration writes retain the previous file and restore the previous model on failure. Real ENOSPC injection verifies saved bytes and theme remain unchanged. |
| Cached session entries and repeated menu opening retained old objects | Evict sessions no longer in the bounded live selection; dispose obsolete provider submenus on rebuild. |
| Two-step material/position changes briefly rendered an intermediate state | Validate, save and update the selected screen in one batch. |
| Display settings lacked the source's screen/mode/drag explanations | Restore source section hierarchy and hints without adding platform branding. |

Live local verification after restart reports Codex quota `available`, no error,
and only the currently open Codex client. The original transient failure had no
structured diagnostic record, so its historical root cause is not established.
The new health file records only client/state/error category/last-success time,
not credentials, conversation text or account identifiers. No model turn is sent.

`native_material_preview.py` renders an explicitly owned sample scene with the
normal Windows Qt backend. Its bounded screen captures include the compositor,
not just QWidget's offscreen pixels. It reads no accounts, launches no agents,
and does not alter the resident configuration. On Windows build 22631 at 1×:

- Native light/dark captures were inspected; both meter and 28pt hover line had
  successful Acrylic calls and native rounded regions. Default 22pt sizing is
  separately checked at a 26pt hover-line height.
- Actual open/close/open reversal settled correctly. The latest sample recorded
  a median 15.24ms and P95 25.52ms between spring callbacks.
- Qt paint/readback P95 was 0.506ms for the compact line and 1.616ms for the full
  panel. Cached soft breathing glow was 0.216ms; grid styles ranged from 1.175ms
  to 3.414ms in that run. These are CPU/readback costs, **not measured GPU frame
  time or an assurance of 60fps on every machine**.

Reproduce fixtures (generated files stay ignored under windows/previews):

```powershell
windows/.venv/Scripts/python.exe -m unittest discover -s windows -p "test_*.py"
windows/.venv/Scripts/python.exe windows/hud.py --preview-dir windows/previews
windows/.venv/Scripts/python.exe windows/native_material_preview.py windows/previews
```

The native probe writes native-light.png, native-dark.png, native-material.json
and ui-performance.json. The fixture renderer writes both light/dark settings
and panel images. They are sample-data evidence, not screenshots of user records.
If a remote/disconnected desktop returns a blank capture, the probe names it
`*-unavailable.png` and records `capture_valid: false`; a blank image is never
accepted as evidence of fidelity. Earlier successful visual observations and
their limitations must be distinguished from an unavailable later capture.
After the desktop became available again, the latest probe captured both themes
successfully (`capture_valid: true`). The images were visually inspected: the
compact line and meter change tint and have rounded surfaces. These replace the
earlier blank captures as current evidence, without establishing pixel identity
with Apple's compositor or a 90% score.

## Acceptance gate and remaining gaps

The upstream Simple tour was inspected for hover/click behavior, and Swift
settings/geometry/palette sources were inspected directly. Original Mac settings
captures are now available from successful macOS reference workflow run
[39160779551](https://github.com/nanhudev/agent-hud-open/actions/runs/39160779551).
That separate verification branch uses unchanged upstream Swift source at
bf19ac9 and does not update the Windows PR. Reference images were inspected at
960×720; compact segmented controls, display row ordering, and the source
wallpaper/HUD preview were corrected against them. There are still typography,
native-control and row-spacing differences, and fixture/client state differs.
Consequently **no numeric similarity score is reported**;
passing tests or matching background pixels is not proof of 90% fidelity.

Apple Liquid Glass/Core Animation and Windows Acrylic/Qt differ. Native Windows
evidence is a necessary separate check; offscreen PNGs alone cannot validate
compositor corners/blur. Native 125% and 150% probes were added; GPU frame time
and other DPI levels remain unmeasured.

MCP layout drafts, the approval bridge, animated Bot direction and the full
historical statistics interface remain unported. English labels/notices are
incomplete. Match-screen currently resolves appearance, not the original full
window glass/transparency propagation. Real signed-in Cursor quota/hook delivery
still needs acceptance with a current Cursor login. None of these gaps is hidden
behind a claim of complete parity or an enabled but unimplemented control.

Native API references: [client-area animation preference](https://learn.microsoft.com/en-us/windows/win32/winauto/client-area-animation),
[DWM border/corner attributes](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute).


## Account and Token correction (current iteration)

The former fixed account labels and duplicated Tokens/Sessions table were not
functional parity. They are replaced by evidence-bearing account labels, cached
account history, real plan names, six Cursor quota pools, official OpenAgent
plan endpoints and a source-keyed SQLite event ledger. Thirteen groups read
local/account Token records and GLM reads plan quotas. Other adapters are not
silently marked supported. The same immutable request identity survives reloads,
stream updates and database polling; cumulative source rows replace one coherent
observation, avoiding per-column MAX overcount. Fifteen-minute buckets drive the
24-hour hover chart; statistics use model totals and update while open. Local
history without account evidence is explicitly labeled local, never assigned to
the current sign-in. Billing/account identity and credentials are not persisted
together. No prompt, model turn, shell key resolver or OAuth refresh is issued.

85 regression checks cover source format examples, Codex inherited history,
Cursor overlapping pages and equal distinct requests, account isolation, safe
official endpoint routing, mixed cache/reasoning layouts, partial records,
legacy SQLite schemas, restart deduplication and live statistics refresh. Native
Windows settings were rendered and inspected with an explicitly synthetic
account; the offscreen backend on this machine produces missing font glyphs and
is not accepted as typography evidence. Real resident Codex health reports an
identified account, valid quota and thousands of indexed usage records; initial
indexing is still labeled incomplete. Health metadata excludes account labels,
identifiers and credentials. Other providers' signed-in Windows acceptance is
still outstanding.

The material now follows the original two-layer fallback: native untinted blur
plus source dimming inside the Qt silhouette. The former 142/138 RGB rectangular
tint defect is substantially reduced. Strengthening the native check from one
sample to all four outside-capsule corners exposed a remaining dark hover
bottom-right residual at 100% (30 RGB levels, limit 16). Native 125% and 150%
probes pass the four sampled corners, but that is not full-shape or overall
fidelity proof. Disabling OS shadow and waiting longer for the backdrop did not
remove the residual; those ineffective app changes were not adopted. These
results supersede earlier single-corner passes. No >=90% claim or PR update is
made. macOS Liquid Glass, drag ordering, complete historical statistics and the
remaining four providers continue to block overall acceptance.


## Latest acceptance — 2026-10-19, focus/corners/source motion

This section supersedes earlier corner failures and the four detection-only gaps.
The user explicitly accepts source/fixture validation for additional agents; real
sign-ins or launching those clients are not acceptance requirements for this run.

- All 18 catalog groups now have registered readers and settings switches. The
  four added ports cover DeepSeek Harness JSONL/zstd, Grok CLI legacy/unified,
  Copilot shutdown/OTEL and Antigravity SQLite/protobuf. Routes include DeepSeek
  balance, Grok credits, Copilot opt-in quota, Antigravity current/legacy service
  metadata and already-running native agy print-usage. This is not a claim of
  Grok Bot desktop-cache parity or every upstream runtime variant.
- The original DeepSeek JavaScript helper is extracted from unchanged upstream
  source, rather than rewriting its credential/YAML or multi-frame zstd logic.
  Helpers are bounded in output, memory and time; custom DeepSeek hosts cannot
  receive requests assumed to belong to the official service.
- Fixtures exercise each local file/database reader through the persisted ledger,
  refresh/restart deduplication, inherited DeepSeek seeds, downward stream
  corrections, Copilot snapshot baselines/late trace joins, ambiguous counters,
  protobuf singular timestamp merging and source-priority reconciliation.
- Full details now request focus on click and dismiss on WindowDeactivate, clear
  the click pin, stop pending hover timers and dismiss the peek. Moving focus
  among child controls does not dismiss the window. Reopening remains possible.
- Native Windows focus verification passes all five checks: opened, received
  focus, other owned window received focus, details closed, pin cleared.
  Reproduce via native_material_preview.py; no other user's apps are controlled.
- Native region bounds no longer add an extra right/bottom pixel. Custom masking
  owns the radius with DWM corner treatment disabled. Both themes pass four
  outside-capsule samples at 100/125/150 percent (max RGB differences 9/7/6 in
  those runs, threshold 16). These samples do not establish full silhouette parity.
- Settings retain separate detail scrolling with a themed transparent viewport,
  fixing a white rectangle in dark mode. Remove the invented Token section from
  SourcesPane. Detected provider-group drag order persists and controls HUD order.
  Per-window ordering, account-visibility grouping and statistics layout remain gaps.
- HUD and peek use IslandAnimation's exact 0.4-second cubic curve (0.2,0.8,0.2,1),
  with velocity-preserving interruption. Controls retain their restrained springs.
  Native reversal settles; measured CPU paint/readback p95: panel 2.081 ms,
  peek 0.496 ms. These are not GPU frame-rate or smoothness guarantees.

105 tests pass. Native dark/light settings were captured and inspected. All Swift
sources remain unchanged. PR visual gate is still **not met**: no numeric >=90%
claim, upstream push/review request or release is made by this iteration. The local
changes can be reviewed in Git without implying upstream endorsement.


## In progress toward the maturity goal — 2026-10-19

The user has explicitly requested continued work until roughly 90% maturity,
including the missing small animations. The goal remains active; this is not a
release or similarity acceptance claim.

- Fix the corrected interaction: clicked details also close on pointer departure,
  without a second click or focus change. Pointer handoff into details cancels
  collapse. A regression covers leave/reenter and deactivation separately.
- Export original BotRenderer/BotMotion frames on macOS without changing Sources.
  Reference build 39212227517 succeeded. All 18 catalog providers have original
  forms in dark/light; the pack also preserves the original additional forms.
  600 clips / 23,184 unique frames are packed into about 22 MB. All 888 generated
  files pass SHA-256 verification. 120 sampled packed frames preserve exact
  premultiplied source pixels and their sRGB profiles.
- Native Windows contact sheets show the original work, thinking, waiting, hover,
  failed and limited looks. A 48-frame native probe observes 47 frame changes.
  Actual one-meter paint/readback p95 is 0.573 ms over 60 frames; contact-sheet
  timing is a separate much heavier 36-character workload. No GPU FPS claim.
- Keep temporally adjacent frames on adjacent atlas pages: this halves pack size
  versus hash ordering and avoids scattering a blinking mark across hundreds of
  pages. Clip/image/page caches are bounded. Reduced motion and hidden windows
  stop the bot clock; missing assets safely retain the original logo.
- Decode only actual Codex call IDs/tool categories; do not retain arguments or
  results. Work endings return to thinking; turn endings clear activity. A bounded
  tail missing task_started no longer erases a full reader's recent running state;
  old evidence still expires. No quota percentage invents a failure/limit event.
- Per-window internal drag and account visibility now persist and affect the
  displayed HUD, preserving full underlying records. Synchronous persistence
  avoids a queued write firing after a settings view has closed.
- Initial stats hierarchy now includes token consumption, an agent breakdown,
  today/7/30-day usage and a heatmap. Source token colors, default exclusion of
  cache reads, time ranges, bucket choices and at-least-one-kind semantics are
  translated. The full original statistics references are building separately;
  model filtering, session detail layouts, pricing and exact range-edge accounting
  are not yet accepted. Initial local discovery now includes 31 days and exposes
  longer ledger history to the statistics view.

116 checks pass. Remaining bot gaps: continuous pointer gaze, all live-status
variants, sprite-specific Clawd and seamless stochastic looping. Remaining release
checks include statistics/source comparison, clean installation, attribution and
third-party binary packaging, and the overall acceptance matrix. Do not treat the
new test count or the source-pixel samples as an overall 90% similarity score.


### Visibility regression after a test launch

A resident launch inherited QT_QPA_PLATFORM=offscreen from the test command.
Health reported visible widgets, but they were not on a native display. Correct
normal hud.py launches to select the Windows platform before importing the UI;
explicit previews/probes retain their requested test environment. Settings now
restore from minimization and clamp an off-display saved position to a current
screen. Health records the actual Qt platform so headless visibility cannot be
confused with native visibility again. Native verification found the restored
settings on screen at [462,116,1438,875], not minimized, and the HUD at
[852,0,1068,24] on P25F200, with qt_platform=windows. All positions are diagnostic
samples from this machine, not hardcoded placements.

A separately created clean Python environment installed only requirements.txt;
all 116 checks at that checkpoint and the passive presence probe passed. Current
statistics changes also add model-bucket queries/model filters using the original
agent palette; per-kind filters retain at least one selection. Model menu actions
are kept alive while toggled rather than rebuilding/deleting the active action.

### Detached-surface clipping and lifecycle follow-up

The earlier four-corner checks covered the small peek, not the full details.
Full-panel native captures exposed Accent blur outside rounded layered HWNDs.
An additional CreateRoundRectRgn disagreed with Qt's mask at fractional scales.
This iteration replaces that backdrop on HUD/peek/details with a bounded,
in-memory sampled frost, drawn through the same path as the tint and content.
Qt alone owns the shape mask; DWM's second frame/radius stays disabled. The
sample remains fixed during a morph and refreshes on reopening or strip
relocation. **Live background changes are not continuously blurred.** This is a
documented Windows adaptation gap, not a claim of native Liquid Glass parity.

Move and resize the detail window in one geometry transaction. Changing an edge
cancels the old origin and detached surfaces. Hiding a strip cancels all hover,
detail and glow clocks. Cached strip coverage permits ordinary label reflow
without dismissing an open panel. Dynamic queues have no capsule mask that cuts
the first/last logos.

126 unit/regression checks pass. Native controlled-wallpaper audits cover 24
mode/configured-edge/theme combinations per scale at 100%, 125% and 150%. Notch
retains upstream's top placement regardless of the stored dock edge. Intermediate
expand/shrink frames, timed reversal, outside corners, a 17pt travel-corridor grid,
the former panel centre after close and full detached-window hiding are checked.
The grid excludes a 2pt fractional-DPI antialias fringe; it is not a pixel-perfect
full-edge comparison. Accepted runs report no out-of-shape tint or trail beyond
the specified tolerance. Native diagnostic PNGs and JSON are under local ignored
`previews/`; they contain only the owned QA wallpaper and sample data.

Further work requested: profile frame time/cold-open cost, refine continuous
curvature and prepare an actual-app demonstration video with clearly labeled
sample usage. A promotional recording is not performance acceptance evidence.
The overall >=90% gate and upstream PR update are still pending.

### Core-feature and settings audit

`PARITY_AUDIT.md` now maps original settings rows and core capabilities to actual
Windows behavior and explicit gaps. Permission/reply cards are implemented in
the shared native surface rather than as promo-only images. Current-user pipe
tests exercise real callback subprocess stdout, cancellation, timeouts, invalid
input, exact Codex reviewer contexts, explicit question/plan answers, transcript
settling/rotation, hook ownership and reversible foreign-config preservation.
Qwen timeout units and ZCode nested events come from the original hook source.
WorkBuddy metering tests cover read-only scope, renamed sessions without log
reparsing, model attribution intersection and invalid credit values.

150 regression checks pass. The integrated native surface matrix again passed
24 combinations at each of 100%, 125% and 150% scaling, within the documented
2pt anti-alias guard and RGB tolerance. Actual permission and reply cards were
captured in both themes and visually inspected. Mouse press alone did not
approve; release inside the same live action did. This is not live-client
certification for every installed client version and not a 90% similarity score.

Source MCP contracts were exported by compiling unchanged Swift definitions on
macOS (Actions run 39223404514) and stored with provenance. MCP runtime/layout
drafts, quota/reset-credit reminders, richer statistics and remaining callback
channels still block the mature-release claim. Performance work and the actual
UI promo remain required; no upstream review is requested on this checkpoint.

### WorkBuddy official subscription and balance

The earlier local `session_usage.credit_json` integration measures spending; it
does not answer subscription or remaining-credit questions. The installed
WorkBuddy 5.5.6 client's own account UI/AuthService identified a separate official
billing-summary metadata API. Its request needs the desktop product/client
headers as well as the existing login. A direct incomplete request returned
HTTP 403/code 10085; the source-compatible request returned code 0 with actual
subscription and package credit counters. The gateway already de-duplicates
subscription packages; sum its summary without another local filtering pass.

Independent Windows adapter, no proprietary client implementation redistributed.
Fixed HTTPS origin, no redirects, in-memory credentials from the existing login
file, no writes to the session and no refresh/check-in/purchase/model request.
The current-user identity is checked again after the request. Enterprise scope
uses its separate route and unlimited is displayed explicitly. Hidden accounts
also hide the new balance. Actual HUD and Agents settings show subscription and
remaining/total credits. Fixture-only native light/dark panels were inspected.
Credential expiry/logout, wrong domain, account switch, invalid counters,
enterprise routing and unlimited sentinel are covered by adapter tests.

161 regression checks passed at this checkpoint. New source-derived quota pace
history and pure threshold/reset-credit tracking tests are included; their full
reminder UI/queue integration remains pending, so those tests are not a claim
that all original alert functionality has shipped.

### Quota news surfaces, queue lifetime and reversal regression

Quota warning/reset and reset-credit grant details now use real painted Windows
cards translated from the original views. Source width (400pt), four-second
presentation lifetime, theme colors, reset/expiry information and the working
statistics action are connected to the quota event tracker. First observations
remain silent. Permission requests are never expired by the news timer; unseen
queued news does not lose its presentation time. Hover holds the currently
presented card, and hidden accounts/windows do not replay old alerts.

The native matrix passed all 24 mode/edge/theme cases at each of 100%, 125% and
150% scaling (72 cases), recorded under `previews/news-accept-{100,125,150}`.
Coverage includes intermediate expansion/collapse and reversal frames, with
the documented 2pt fractional-DPI guard and RGB tolerance. Initial failures
revealed a stored-edge mismatch for top-only notch reminders and stale leave
timers closing a newly reopened panel; both now have regression coverage.
The auditor also now explicitly raises only its owned layers and accounts for
reminder hover opening the full card. Earlier failed captures remain evidence
of those failures, not accepted results. News light/dark captures were inspected.

169 regression tests passed for this checkpoint. The five quota metric picker,
dedicated warning/reset bot artwork, remaining callback channels, full MCP draft
workflow and richer source statistics still require work. Sampled glass remains
frozen while open. These results do not establish 90% parity or sustained FPS.

Promo Token samples are isolated in `promo_fixtures.py`: no client, account,
network or ledger writes. Its graph/model/session totals share one dataset;
recordings must visibly disclose demo data. The resident app does not import it.
With the two sample consistency tests, 171 tests pass. The actual TokenDashboard
was rendered for four agents in both themes using the native Windows platform;
Codex dark and WorkBuddy light were visually inspected. Qt's offscreen plugin
rendered missing font glyphs on this machine, so those offscreen captures were
discarded and replaced by native captures. This is a still preview, not a video.

### Staying reminder actors: implementation, export pending

Re-reading `ReminderMark.swift` corrected the prior audit's reference to a
"warning bot": original quota warnings are plain logos; exhaustion adds the
static hourglass sign, while reset/reply/request cards have their own actors.
News must not replace the dock's current working state. The Windows selection
now follows that distinction and gives permission/question/plan their priority.

The actual alert painters are connected to a separate visible-only actor on the
shared clock. Hiding clears it; a new card restarts arrival; repeated playback
does not repeat the logo-to-bot entrance. Reduced motion and disabled bot logos
retain static artwork. A supplementary export uses unchanged `BotMotion` and
`BotRenderer`, `staysBot=true` and the source `BotMark.arrival`, with six original
reminder states. Export QA commit `bf050f6160634c46b065d75f1b63c1824f979664`;
Actions run `39232230900` was still queued when this checkpoint was written.
There is no supplementary pack yet: actual animated card capture and integration
acceptance remain pending. The native preview fails explicitly if that pack is
missing. This code checkpoint is not a claim that reminder animation has shipped.
Claude's source procedural recording form is used; the separate proprietary-app
sprite performer, including its special long-reply/reset clips, is not ported.

173 tests pass, including dock/request selection and reminder visibility/new-card
clock behavior. A native four-agent 24fps playback benchmark (144 timer frames)
measured CPU paint p50 0.489ms, p95 10.749ms, worst 87.193ms including initial
asset loading. Timer interval p50 41.996ms, p95 42.712ms, worst 43.467ms; no interval
exceeded 1.5 target frames in this run. Evidence:
`E:/AI-Data/agent-hud-promo-20261019/playback-cpu.json`. This covers an owned Qt
window's CPU/event loop, not GPU/vsync, full resident activity, or a universal FPS
claim. Cold loading still deserves optimization before the performance gate.

### Reminder export accepted; continuous-corner and unknown-value regression

Actions run `39232230900` succeeded. The supplementary pack contains 240 original
reminder clips, 5,669 unique images and 6,275,434 bytes before extra provenance
fields. All 311 packed file hashes and 120 sampled premultiplied PNG pixels
match the original export. The unchanged source keeps the initial logo through
its card-opening delay and the bot raised afterwards. All agents/themes/six
states have pack tests. The original procedural Claude recording form is used;
this does not claim its separate Clawd sprite performer is ported.

Actual Windows panels were captured for request/reply/reset, dark and light,
at six recording times each: four changes among five adjacent pairs per case.
Evidence: `E:/AI-Data/agent-hud-promo-20261019/actual-reminder-animations-native`.
Dark reply and light request were visually inspected over the owned QA backdrop.
Transparent QWidget grabs were replaced with bounded native screen capture to
avoid interpreting transparent-image fringes as desktop compositor evidence.

`surface_shape.py` provides two cubic segments per continuous panel corner,
matching second derivatives at the diagonal and zero curvature at straight
edges. It approximates the platform-specific SwiftUI continuous contour; it
does not assert Apple's exact path. Circular capsules and notch-specific geometry
remain source-shaped. Fill and native clip share this path. The 24-case news
matrix passed at 100%, 125%, 150% (72 cases) within the existing 2pt/RGB tolerance;
dark left-edge details were inspected. Evidence is under
`E:/AI-Data/agent-hud-promo-20261019/continuous-{100,125,150}`.

Unknown/invalid quota values no longer crash the panel or become a numeric zero:
panel, meter selection and peek preserve an unknown value. Its actual paint path
is covered for null, non-finite and boolean readings. All 177 regression tests
passed, including complete supplementary pack coverage.
Special tiny-mark sign sampling, pointer gaze, richer settings/statistics, MCP,
remaining callback channels, performance and the full promo/release gates remain.
