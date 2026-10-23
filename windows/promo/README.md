# Agent HUD Open — Windows preview film

The primary `OriginalStyleTour` is 36 seconds, 1920 × 1080, 30 fps, with a real
desktop and short bottom captions matching the original tour's presentation.
The alternate `WindowsPromo` composition is a 40-second titled edit.
This is a development preview, not an official
Windows release or a claim that the port has reached release parity.

Original project: https://github.com/jazzenchen/agent-hud-open by jazzenchen.
Windows port: nanhudev. Original project license: Apache-2.0; source and notices
remain in the repository. Third-party product names and marks belong to their
respective owners. No endorsement is claimed.

Structure follows the original simple-mode tour: dock, hover, details,
approval, reply, placement/mode. Windows settings, account information and
token statistics follow as port-specific demonstrations.

Product pixels are captured from the implemented Windows Qt widgets and the
Windows desktop compositor, with source animation drivers stepped on an offline
recording clock. Remotion adds camera framing, titles, credits and transitions;
it does not recreate the panels or invent unimplemented product animation.

Accounts, plans, quotas, credits, tasks, token histories and messages are explicit
demo fixtures. No live account is read or modified. No provider, callback,
purchase, credential write, real UsageLedger write or resident setting change
is performed by the recorder. The tiny bot is the procedural source renderer,
not the separately licensed Anthropic sprite sheet.

Wallpaper is an original procedural gradient and curves. Soundtrack is original
programmatic synthesis (120 BPM, 48 kHz stereo) without third-party samples.
No downloaded music or unknown-license reference wallpaper is used.

Reproduce:

1. Copy this `promo` folder to a working directory on a drive with free space.
   From the Windows repo, run `windows/promo_record.py <film>/public/footage-v2`
   with `QT_QPA_PLATFORM=windows` and the project's Python environment. The
   recorder needs a 1920 × 1080 desktop at 100% scaling; capture bounds are
   deliberately fixed and it rejects a different capture scale.
2. From that working directory, run `make_music.py` with Python + NumPy.
3. Run `npm ci` to install the dependencies locked in `package-lock.json`.
   Keep npm cache and TEMP on a drive with sufficient free space.
4. Run `npx remotion render src/index.tsx OriginalStyleTour out/preview.mp4
   --codec h264 --crf 17 --concurrency 4`. If necessary, add
   `--browser-executable` pointing to your installed Edge/Chromium executable.
5. Inspect encoded frames at each chapter and verify audio/metadata before sharing.

Capture manifest: `public/footage-v2/capture.json`.

The resident app never imports this composition, the recorder or the fixtures.
