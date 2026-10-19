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
  tokens. Windows Acrylic tint uses ABGR, including Clear/Regular fallback; the
  untinted legacy Clear path no longer leaves light surfaces dark. Both Qt and
  native window regions are rounded; the additional DWM border is disabled.
- Panels morph from their actual source bounds; their content keeps a fixed
  layout during expansion. Springs preserve current value and velocity under
  reversal. Switch press compression and restrained card lighting do not move
  hit boxes. Springs sleep at rest; reduced motion disables continuous effects.
- Also corrected: top-edge opening only triggers at the actual screen edge;
  pressing Alt while already hovering works; reset labels show real countdowns;
  settings writes replace an atomic temporary file.

## Verification

63 tests pass locally, including real control clicks through persistence and
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
  Only Codex/Cursor currently have live data adapters; other groups say this
  explicitly instead of presenting nonfunctional monitoring switches.
- Restore persisted, bounded per-screen versions: style reset, layout reset and
  use-shared can be reverted after restart. Glass and Solid retain separate
  transparency values; old saved values migrate without being discarded.
- Compact segment metrics, selected tint, numeric slider labels, disabled
  buttons and settings section spacing now follow the source more closely.
  Per-quota-window visibility leaves the original readings intact.

Native 125% and 150% scale probes both captured dark/light scenes and successful
Acrylic calls. These exposed an additional **unresolved blocker**: Acrylic's
outer backdrop can remain a rectangle with the OS's small corners even though
Qt paint and GetWindowRgn report the intended capsule. A new outside-capsule
pixel check compares the surface against the same owned wallpaper before the
overlay exists; on the light 100% sample its meter/peek deltas were 142/138 RGB
levels (threshold 16), so both failed. Native region success alone is no longer
accepted as proof that the visible material is clipped correctly. Tests with no
OS rounding, an opaque Qt host, the legacy DWM blur region and removing the
layered style did not fix it and were not adopted.

Current PR gate: **FAIL / below verified acceptance**, with no invented numeric
score. Blocking differences include the Acrylic silhouette, 16 providers without
live Windows adapters, provider/window drag ordering, incomplete English, Apple
material/transition differences and the previously recorded unported interfaces.
The Windows PR branch has not been pushed with these changes. Source-geometry
checks passing, a successful capture, or large matching background areas cannot
establish overall 90% similarity.

## Additional bad cases collected and corrected

| Case | Correction and evidence |
| --- | --- |
| One failed quota read erased usable values for three minutes | Keep the last successful reading with an explicit stale label; retry after 15/30/60/120/180 seconds from failure completion, reset on recovery. |
| Loading, missing percentages, expired login and network failure all looked unavailable | Distinct safe states in meter tooltips, peek tooltips, full panel and tray; manual Refresh quota action. Unknown exception strings are never copied to UI or diagnostics. |
| Authentication and network failures had the same Codex message | Classify auth/network/throttle responses; timeout, storage and disk-full categories are explicit. |
| An empty multi-bucket response hid valid legacy quota | Fall back to the legacy bucket; accept real zero, skip null/malformed/nonfinite values. |
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
