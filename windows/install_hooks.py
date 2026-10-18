"""Merge optional Cursor observers without replacing unrelated hooks."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
import subprocess
import sys

SCRIPT = Path(__file__).with_name('cursor_hook.py').resolve()


def configure(path, remove=False):
    data = json.loads(path.read_text(encoding='utf-8-sig')) if path.exists() else {'version': 1, 'hooks': {}}
    if data.get('version', 1) != 1:
        raise ValueError('Unsupported hooks version; existing file was not changed')
    if path.exists():
        shutil.copy2(path, path.with_name('hooks.json.agent-hud-backup-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f')))
    hooks = data.setdefault('hooks', {})
    for event in ('beforeSubmitPrompt', 'stop'):
        entries = [entry for entry in hooks.get(event, [])
                   if str(SCRIPT).casefold() not in entry.get('command', '').casefold()]
        if not remove:
            entries.append(dict(command=subprocess.list2cmdline([sys.executable, str(SCRIPT), event]), timeout=5, failClosed=False))
        if entries:
            hooks[event] = entries
        else:
            hooks.pop(event, None)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.agent-hud.tmp')
    temporary.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    temporary.replace(path)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--remove', action='store_true')
    args = parser.parse_args()
    configure(Path.home() / '.cursor/hooks.json', args.remove)
    print('Cursor observers removed' if args.remove else 'Cursor observers installed')
