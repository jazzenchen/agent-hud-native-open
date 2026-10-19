# Windows runtime dependencies

These packages are installed into the local ignored `.venv`; no runtime binaries
are committed or redistributed here. Their licenses are independent of this
repository's Apache-2.0 license.

- [Qt for Python / PySide6 and Shiboken](https://doc.qt.io/qtforpython-6/licenses.html):
  Qt's LGPL/GPL/commercial licensing terms; use the license files distributed with
  the selected PySide6-Essentials and shiboken6 packages. The application imports
  the unmodified dynamically installed packages. Qt modules remain replaceable.
- [psutil](https://github.com/giampaolo/psutil/blob/master/LICENSE): BSD 3-Clause.
- [Python](https://docs.python.org/3/license.html): Python Software Foundation terms.

Original client artwork stays in `Sources/AgentHUDDesktop/Resources` and retains
the repository's `THIRD_PARTY_NOTICES.txt` / `docs/brand-assets.md` attribution.

- [Node.js](https://github.com/nodejs/node/blob/main/LICENSE): separately installed
  runtime for the original DeepSeek balance and zstd scripts; no Node binary is
  redistributed. Use Node 24+ with built-in zstd support.

The Windows adaptation reuses unchanged upstream source files for design constants,
artwork and the DeepSeek helper scripts. Additional provider parsers translate the
original formats, retaining the CodexBar/Tokscale notices in the repository's
THIRD_PARTY_NOTICES.txt. The original Apache-2.0 license and all attribution must
accompany source redistribution. No endorsement or joint-development agreement
is claimed. A bundled binary release needs a separate dependency-license review.


`windows/assets/bots` contains generated output of the repository's unchanged
Apache-2.0 BotRenderer/BotSpec/BotForm/BotMotion, using the original bundled agent
artwork. Original artwork notices remain applicable. The original drawn Claude
fallback is used here; this pack does not add or redistribute Clawd game sprite
sheets. `provenance.json` records the original revision and every generated file.

`windows/assets/bot-reminders` likewise contains generated procedural reminder
frames from unchanged original BotRenderer/BotMotion code, with its own export
provenance. Neither Windows actor pack uses `clawd-sprites.json`; that existing
upstream asset remains separately identified as Anthropic artwork in the
original `THIRD_PARTY_NOTICES.txt` and is not relicensed by the Windows port.

The optional `windows/promo` video tooling references [Remotion's own license](https://www.remotion.dev/license),
not Apache-2.0. Remotion and React packages are development dependencies installed
separately; no dependency runtime is redistributed in this source preview, and
the resident HUD does not load them. See each selected package's license before
using that tooling. The published preview uses original programmatically
synthesized music with no third-party samples and an original procedural
wallpaper. Its product names/marks remain their respective owners' property.
