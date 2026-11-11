#!/usr/bin/env python3
"""Make preview.png: the real popup, photographed, for the marketplace card.

Nothing here is a mock. The registry is written by the running Pi extensions, so
the sessions in the card are live: this script starts two throwaway headless Pi
sessions with `pi --print`, summons the popup through the shell's own IPC, takes
the screen with grim, and crops the card.

The card is anchored under the tray, at the right edge, so its region is fixed
and documented: 520x240 at (1920-520, 0), which includes the bar so the pi icon
is in the shot. The crop is scaled 2.3x to fill the card's 1200x675 and padded
with the theme background, which the marketplace optimises itself.

The registry and any open panel are left as they were found.

Requires a running Omarchy session: a layer-shell popup has no backend offscreen,
so this cannot run inside the contract suite.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "preview.png"
W, H = 1200, 675
SCREEN_W, SCREEN_H = 1920, 1080
# The card, as the shell anchors it: under the tray, flush right, bar included.
CARD = (SCREEN_W - 520, 0, 520, 240)
SCALE = 2.3
BG = os.environ.get("OMARCHY_PREVIEW_BG", "#14151b")
PROMPTS = [
    "use the bash tool to run exactly: sleep 70 && echo READY_A, then reply only: A done",
    "use the bash tool to run exactly: sleep 60 && echo READY_B, then reply only: B done",
]


def sh(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(list(args), capture_output=True, text=True, check=False)


def sessions() -> list[dict]:
    path = Path.home() / ".cache/pi-presence/sessions.json"
    if not path.exists():
        return []
    try:
        return (json_loads(path.read_text()) or {}).get("sessions", [])
    except Exception:
        return []


def json_loads(text: str):
    import json
    return json.loads(text)


def main() -> int:
    for tool in ("grim", "magick", "omarchy-shell", "pi"):
        if shutil.which(tool) is None:
            print(f"{tool} is required", file=sys.stderr)
            return 1
    if not os.environ.get("WAYLAND_DISPLAY"):
        print("needs a running Wayland session: the popup is a layer-shell surface",
              file=sys.stderr)
        return 1

    tmp = Path("/tmp/pi-presence-preview")
    tmp.mkdir(exist_ok=True)
    procs = []
    open_before = sh("hyprctl", "layers").stdout.count("omarchy-keyboard-panel")

    try:
        # Two real sessions, working. The card needs more than one row to show
        # what it is for, and the only honest rows are live ones.
        for prompt in PROMPTS:
            procs.append(subprocess.Popen(["pi", "--print", prompt],
                                           stdout=subprocess.DEVNULL,
                                           stderr=subprocess.DEVNULL))
        deadline = time.time() + 40
        while time.time() < deadline and len(sessions()) < 2:
            time.sleep(1)
        time.sleep(2)

        sh("omarchy-shell", "shell", "hide", "pi.presence")
        time.sleep(0.8)
        sh("omarchy-shell", "shell", "summon", "pi.presence", "{}")
        time.sleep(2.2)
        shot = tmp / "open.png"
        sh("grim", str(shot))
        sh("omarchy-shell", "shell", "hide", "pi.presence")

        x, y, w, h = CARD
        sh("magick", str(shot), "-crop", f"{w}x{h}+{x}+{y}", "+repage",
           "-filter", "Lanczos", "-resize", f"{int(SCALE * 100)}%",
           "-background", BG, "-gravity", "center", "-extent", f"{W}x{H}", str(OUT))
        print(f"{OUT} <- {len(sessions())} live session(s), card {w}x{h} at {x},{y}")
    finally:
        for p in procs:
            p.terminate()
        if not open_before:
            sh("omarchy-shell", "shell", "hide", "pi.presence")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
