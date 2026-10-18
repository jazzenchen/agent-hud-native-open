# Windows companion (experimental)

Small Python/Tk panel for **Codex Desktop/CLI and Cursor**, additive to the Swift
app. No third-party Python dependencies. Requires Python 3.10+ with Tk from the
python.org Windows installer. Keep this checkout in place after installation.

```powershell
cd windows
.\install.ps1
# Optional login startup: .\install.ps1 -Startup
# No Cursor observers: .\install.ps1 -NoCursorHooks
```

Creates a Desktop shortcut and a pinned floating window. Pin can be disabled;
Compact hides the sessions. Closing the window exits. Startup is opt-in.

| Client | Activity | Usage |
| --- | --- | --- |
| Codex | Latest 12 nonarchived session records, bounded rollout tails, explicit task start/end/abort | Per-session cumulative tokens; installed app-server `account/rateLimits/read` |
| Cursor | Local composer titles and optional `beforeSubmitPrompt` / `stop` observers for new turns | Existing login with `https://cursor.com/api/usage-summary` |

Activity refreshes every 3 seconds; quota every 3 minutes. Unknown quotas stay
unavailable. Expired Cursor login requires signing in again in Cursor. Last seen
is not a completed task; a running marker expires after 30 minutes of silence.
Token counts are session lifetime cumulative counters, not today's consumption;
parent/child counters are not summed. Cursor may need a reload/new chat for hooks.

This is an experimental companion, not full Windows parity: other providers, Host
API, approval controls, tray, notifications, global usage accounting, session
navigation and the macOS glow are out of scope. The Swift providers remain the
reference for protocol changes. Uses this repository's Apache-2.0 license and
existing third-party notices.

## Data boundaries

- Reads `%CODEX_HOME%` (default `~/.codex`) and
  `%APPDATA%/Cursor/User/globalStorage/state.vscdb` read-only, including live WAL.
- Codex engine discovered in PATH or `%LOCALAPPDATA%/OpenAI/Codex/bin/*/codex.exe`.
- Cursor token only in memory for its provider's HTTPS request. No redirects.
- No prompts, commands, replies or credentials are persisted; no model turn starts.
- Own activity metadata and error classes: `%LOCALAPPDATA%/AgentHUDOpen`.
- Optional user hooks are backed up beside `~/.cursor/hooks.json`. Unrelated hooks
  are preserved. The prompt observer returns `{"continue":true}`, the stop
  observer `{}`; neither returns tool approval decisions or follow-up prompts.

## Validate / remove

```powershell
# From repository root
python -m unittest discover -s windows -p "test_*.py" -v
python windows/hud.py --probe
python windows/hud.py
# Remove only this checkout's observers
python windows/install_hooks.py --remove
```

Close the app and delete its Desktop/Startup shortcuts to uninstall. Client data
and unrelated hooks remain. Live account queries and Cursor-emitted hook delivery
need manual verification with signed-in installed clients.
