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

42 tests pass locally, including real control clicks through persistence and
rendered-pixel checks for window/HUD/panel/peek light/dark changes. Regressions
cover live menu dispatch, click versus drag, compact hover versus click-to-pin,
rapid reversal, stable spring integration, reduced motion, and canceled/keyboard
switch activation. Existing data/presence/hook checks remain in the suite.
Style reset also persists glass/glow defaults while preserving panel layout.
A newly started spring no longer inherits time spent on an earlier animation
while the UI was busy rebuilding; a regression covers that first-frame jump.

`native_material_preview.py` renders an explicitly owned sample scene with the
normal Windows Qt backend. Its bounded screen captures include the compositor,
not just QWidget's offscreen pixels. It reads no accounts, launches no agents,
and does not alter the resident configuration. On Windows build 22631 at 1×:

- Native light/dark captures were inspected; both meter and 28pt hover line had
  successful Acrylic calls and native rounded regions. Default 22pt sizing is
  separately checked at a 26pt hover-line height.
- Actual open/close/open reversal settled correctly. The latest sample recorded
  a median 17.24ms and P95 25.21ms between spring callbacks.
- Qt paint/readback P95 was 0.585ms for the compact line and 3.135ms for the full
  panel. Cached soft breathing glow was 0.404ms; grid styles ranged from 2.175ms
  to 4.977ms in that run. These are CPU/readback costs, **not measured GPU frame
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
The latest probe returned blank captures for both themes. Native Acrylic calls
and rounded regions succeeded, but latest compositor fidelity is unverified.

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
compositor corners/blur. Other DPI levels and GPU frame time remain unmeasured.

MCP layout drafts, the approval bridge, animated Bot direction and the full
historical statistics interface remain unported. English labels/notices are
incomplete. Match-screen currently resolves appearance, not the original full
window glass/transparency propagation. Real signed-in Cursor quota/hook delivery
still needs acceptance with a current Cursor login. None of these gaps is hidden
behind a claim of complete parity or an enabled but unimplemented control.

Native API references: [client-area animation preference](https://learn.microsoft.com/en-us/windows/win32/winauto/client-area-animation),
[DWM border/corner attributes](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute).
