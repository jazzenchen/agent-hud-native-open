#!/usr/bin/env python3
"""Write Clawd's sprites, the ones Agent HUD's clips play, from an installed Claude app into Agent HUD's resources.

Clawd's frames are the Claude desktop app's own: they come from Clawd Quest, the game it ships. The game's script,
.vite/renderer/main_window/assets/clawdQuestEngine-*.js inside the app's app.asar, holds the sprite table as
JavaScript literals, one object a sprite:

    Walking:{cat:"Core",w:24,h:18,fps:12,palette:["#141413",...],base:"...",deltas:"...".split("("),a0:[...],standMatch:1}

This reads that table, keeps the sprites ClawdClips.swift's frameCounts names, unchanged, and writes them to
Sources/AgentHUDDesktop/Resources/clawd-sprites.json, where the app decodes them once (ClawdSheetSource):

    {"claude": "<the app's version>", "sprites": {"<name>": {<the game's own fields>, "deltas": [...]}, ...}}

Each sprite keeps the game's fields; only its deltas, which the game writes as a list or as one string it splits, are
always a list. Nothing is written when a sprite is missing, does not decode, or has another number of frames than
frameCounts says: the game has redrawn it, and the clips that play it need a look first.

The art is Anthropic's (see THIRD_PARTY_NOTICES.txt). Run this by hand to take in a new Claude app, standard library
only, then the tests: swift test --filter 'ClawdBundledSheetTests|ClawdClipsTests'.

Usage: python3 -I scripts/clawd-sprites.py [path to Claude.app, default /Applications/Claude.app]
"""
import argparse
import json
import plistlib
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Sources/AgentHUDDesktop/Resources/clawd-sprites.json"
CLIPS = ROOT / "Sources/AgentHUDDesktop/Bots/Clawd/ClawdClips.swift"
SCRIPT_FOLDER = ".vite/renderer/main_window/assets"
FIELDS = ["cat", "w", "h", "fps", "palette", "base", "deltas", "a0", "standMatch"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", nargs="?", default="/Applications/Claude.app", type=Path)
    args = parser.parse_args()

    counts = clip_frame_counts()
    version = app_version(args.app)
    table = game_script(args.app / "Contents/Resources/app.asar")
    sprites, problems = {}, []
    for name in sorted(counts):
        sprite = find_sprite(table, name)
        if sprite is None:
            problems.append(f"{name}: not in the game's sprite table, or does not decode")
        elif frame_count(sprite) != counts[name]:
            problems.append(f"{name}: {frame_count(sprite)} frames, the clips were written for {counts[name]}")
        else:
            sprites[name] = sprite
    if problems:
        sys.exit("Nothing written. Claude " + version + ":\n  " + "\n  ".join(problems))

    # One sprite a line, so a new version of the game shows as the sprites it changed.
    lines = [f"    {json.dumps(name)}: {json.dumps(sprite, separators=(',', ':'))}" for name, sprite in sprites.items()]
    text = f'{{\n  "claude": {json.dumps(version)},\n  "sprites": {{\n' + ",\n".join(lines) + "\n  }\n}\n"
    old = OUTPUT.read_text() if OUTPUT.exists() else None
    OUTPUT.write_text(text)
    state = "unchanged" if old == text else "written"
    print(f"{OUTPUT.relative_to(ROOT)} {state}: {len(sprites)} sprites of Claude {version}, {len(text.encode())} bytes")


def clip_frame_counts():
    """The sprites the clips play and the number of frames each had when they were written, by the game's names."""
    match = re.search(r"frameCounts: \[((?:\s*\.\w+: \d+,?)+)\s*\]", CLIPS.read_text())
    if not match:
        sys.exit(f"{CLIPS.relative_to(ROOT)}: no frameCounts table")
    # ClawdSpriteName's cases are the game's names with a small first letter.
    return {case[0].upper() + case[1:]: int(count) for case, count in re.findall(r"\.(\w+): (\d+)", match.group(1))}


def app_version(app):
    """The app's version and build, the way ClawdSheet names the version its sprites come from."""
    try:
        with open(app / "Contents/Info.plist", "rb") as file:
            info = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException) as error:
        sys.exit(f"{app}: not an app ({error})")
    short, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
    if short and build and short != build:
        return f"{short} ({build})"
    return short or build or "unknown"


def game_script(asar):
    """The text of Clawd Quest's script inside an Electron archive.

    The archive starts with two Chromium pickles: the first holds the size of the second, the second the table of
    contents as a length-prefixed JSON string. A file's offset counts from the end of the second pickle.
    """
    try:
        with open(asar, "rb") as file:
            size_payload, table_size, _, json_length = struct.unpack("<4I", file.read(16))
            if size_payload != 4 or json_length + 8 > table_size:
                sys.exit(f"{asar}: not an Electron archive")
            root = json.loads(file.read(json_length))
            folder = root
            for part in SCRIPT_FOLDER.split("/"):
                folder = folder["files"][part]
            names = sorted(name for name in folder["files"] if name.startswith("clawdQuestEngine-") and name.endswith(".js"))
            for name in names:
                entry = folder["files"][name]
                if entry.get("unpacked"):
                    continue
                file.seek(8 + table_size + int(entry["offset"]))
                script = file.read(entry["size"]).decode("utf-8", errors="replace")
                if "standMatch" in script:
                    return script
    except (OSError, KeyError, ValueError, struct.error) as error:
        sys.exit(f"{asar}: cannot read the game's script ({error!r})")
    sys.exit(f"{asar}: no clawdQuestEngine script with a sprite table in {SCRIPT_FOLDER}")


def find_sprite(script, name):
    """The first object written for `name` that holds a sprite which decodes: the nine fields Agent HUD reads, in its own order."""
    for match in re.finditer(r"(?<![\w$])([\"']?)" + re.escape(name) + r"\1:\{", script):
        try:
            fields, _ = Literal(script, match.end() - 1).value()
        except ValueError:
            continue
        if not isinstance(fields, dict) or not all(key in fields for key in ("w", "h", "palette", "base", "deltas")):
            continue
        sprite = {key: fields[key] for key in FIELDS if key in fields}
        if isinstance(sprite["deltas"], str):
            sprite["deltas"] = [sprite["deltas"]]
        if decodes(sprite):
            return sprite
    return None


def frame_count(sprite):
    return 1 + len(sprite["deltas"])


def decodes(sprite):
    """Whether every frame decodes the way ClawdSpriteTable decodes it: base-36 palette indexes, `.` for clear."""
    width, height, palette = sprite["w"], sprite["h"], sprite["palette"]
    if not (isinstance(width, int) and isinstance(height, int) and width > 0 and height > 0) or not palette:
        return False
    pixels, colors = width * height, len(palette)
    if not all(isinstance(color, str) and re.fullmatch(r"#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})", color)
               for color in palette):
        return False

    def index(character):
        return character == "." or (character.isalnum() and character.isascii() and int(character, 36) < colors)

    if len(sprite["base"]) != pixels or not all(index(character) for character in sprite["base"]):
        return False
    for delta in sprite["deltas"]:
        if not isinstance(delta, str):
            return False
        for change in filter(None, delta.split(",")):
            # The game reads a change too short to name a pixel as no change at all.
            if len(change) < 2:
                continue
            if not change[:-1].isalnum() or not change[:-1].isascii() or int(change[:-1], 36) >= pixels:
                return False
            if not index(change[-1]):
                return False
    return True


class Literal:
    """Reads one JavaScript literal of the kinds a sprite table is written with: objects, arrays, strings and
    numbers, `!0` and `!1`, and a string split by a separator. Anything else is a ValueError."""

    NUMBER = re.compile(r"-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
    NAME = re.compile(r"[A-Za-z0-9_$]+")
    ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\n": ""}

    def __init__(self, text, at):
        self.text, self.at = text, at

    def value(self):
        """The literal and where it ends."""
        return self.read(), self.at

    def skip(self):
        while self.at < len(self.text) and self.text[self.at] in " \t\r\n":
            self.at += 1

    def take(self, character):
        self.skip()
        if self.text.startswith(character, self.at):
            self.at += 1
            return True
        return False

    def read(self):
        self.skip()
        character = self.text[self.at:self.at + 1]
        if character == "{":
            return self.object()
        if character == "[":
            return self.array()
        if character and character in "\"'`":
            return self.split(self.string())
        if character == "!":
            self.at += 1
            return self.number() == 0
        if character and character in "-.0123456789":
            return self.number()
        match = self.NAME.match(self.text, self.at)
        if match and match.group() in ("true", "false"):
            self.at = match.end()
            return match.group() == "true"
        raise ValueError(f"no literal at {self.at}")

    def object(self):
        self.at += 1
        fields = {}
        while not self.take("}"):
            self.skip()
            if self.text[self.at:self.at + 1] in ("\"", "'"):
                key = self.string()
            else:
                match = self.NAME.match(self.text, self.at)
                if not match:
                    raise ValueError(f"no key at {self.at}")
                key, self.at = match.group(), match.end()
            if not self.take(":"):
                raise ValueError(f"no colon at {self.at}")
            fields[key] = self.read()
            if not self.take(","):
                if not self.take("}"):
                    raise ValueError(f"no end of object at {self.at}")
                break
        return fields

    def array(self):
        self.at += 1
        values = []
        while not self.take("]"):
            values.append(self.read())
            if not self.take(","):
                if not self.take("]"):
                    raise ValueError(f"no end of array at {self.at}")
                break
        return values

    def string(self):
        quote, self.at = self.text[self.at], self.at + 1
        pieces = []
        while self.at < len(self.text):
            character = self.text[self.at]
            self.at += 1
            if character == quote:
                return "".join(pieces)
            if quote == "`" and character == "$" and self.text.startswith("{", self.at):
                raise ValueError("a template with a placeholder is code")
            if character != "\\":
                pieces.append(character)
                continue
            escaped = self.text[self.at:self.at + 1]
            self.at += 1
            if escaped in ("x", "u"):
                digits = 2 if escaped == "x" else 4
                pieces.append(chr(int(self.text[self.at:self.at + digits], 16)))
                self.at += digits
            else:
                pieces.append(self.ESCAPES.get(escaped, escaped))
        raise ValueError("a string that does not end")

    def split(self, text):
        """A string, or its pieces when it is split right away: `"a(b".split("(")`."""
        start = self.at
        self.skip()
        if not self.text.startswith(".split(", self.at):
            self.at = start
            return text
        self.at += len(".split(")
        self.skip()
        separator = self.string()
        if not separator or not self.take(")"):
            raise ValueError(f"a split that is not by a string at {self.at}")
        return text.split(separator)

    def number(self):
        match = self.NUMBER.match(self.text, self.at)
        if not match:
            raise ValueError(f"no number at {self.at}")
        self.at = match.end()
        number = float(match.group())
        return int(number) if number.is_integer() and abs(number) < 1e9 else number


if __name__ == "__main__":
    main()
