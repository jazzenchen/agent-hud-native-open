"""Observe only: no prompts, commands or responses are persisted."""
import hashlib
import json
import os
from pathlib import Path
import sys
import time


def record(event, payload, directory):
    sid = payload.get('conversation_id') or payload.get('session_id')
    if not sid:
        return
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / (hashlib.sha256(str(sid).encode()).hexdigest()[:32] + '.json')
    roots = payload.get('workspace_roots') or []
    title = Path(roots[0]).name if roots and isinstance(roots[0], str) else 'Cursor · ' + str(sid)[:8]
    state = 'running' if event == 'beforeSubmitPrompt' else 'done'
    if event == 'stop' and payload.get('status') in ('aborted', 'error'):
        state = 'stopped' if payload['status'] == 'aborted' else 'error'
    row = dict(id=str(sid), title=title, state=state, updated=time.time(), tokens=None)
    temporary = target.with_suffix('.' + str(os.getpid()) + '.tmp')
    temporary.write_text(json.dumps(row), encoding='utf-8')
    os.replace(temporary, target)


if __name__ == '__main__':
    try:
        payload = json.loads(sys.stdin.read())
        base = Path(os.environ.get('LOCALAPPDATA', Path.home() / '.local/share')) / 'AgentHUDOpen'
        record(sys.argv[1], payload, base / 'cursor-events')
    except Exception:
        pass  # Monitoring must never block a user's agent.
    # Use the event's documented response schema; never block prompt submission.
    print('{"continue":true}' if len(sys.argv) > 1 and sys.argv[1] == 'beforeSubmitPrompt' else '{}')
