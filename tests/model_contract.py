#!/usr/bin/env python3
"""pi.presence: the widget's own decisions, checked without a compositor, a
running pi, or a theme reload.

What breaks silently here is not the drawing:

  * the state sort — a session waiting on you has to be the first row the
    keyboard walks, or the popup is decoration;
  * the torn read — the extension writes sessions.json in place and the watcher
    fires mid-write, so a partial file has to read as "keep the last frame"
    rather than "no sessions", which would blank the bar every few seconds;
  * staleness — a pi killed mid-work must not leave a row that the jump button
    takes you nowhere;
  * the glyphs — every state the extension can publish needs a codepoint, and
    a missing one shows as a box in the bar;
  * the jump argv — hl.dsp.window.bring_to_top reports success and never moves
    focus, which is how the notification's button was dead for a week.

tests/qml/shell.qml drives the real Model.js and the real bar widget, with
qs.Ui's PopupCard replaced by a plain Item (a layer-shell popup has no backend
offscreen). This builds that harness, reads the tally, and adds the checks that
belong to the files rather than the runtime: the font, the manifest, and the
plain-text rule for anything a tool can influence.

Needs quickshell and Omarchy's qs.Commons / qs.Ui, which the harness links in.
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The plugin is flat at the repository root: that is the layout the marketplace
# validates ("a valid manifest.json in the repository root"), and it is also the
# shape ~/.config/omarchy/plugins/<id> takes when installed.
PLUGIN = ROOT
# CI points this at a pinned checkout of Omarchy's shell/ directory.
SHELL = Path(os.environ.get("OMARCHY_SHELL", "/usr/share/omarchy/shell"))

# A check that cannot run fails: a skip that reads as a pass lets breakage ship.
if shutil.which("quickshell") is None:
    raise SystemExit("quickshell is not installed; the widget's logic cannot be checked")
if not SHELL.is_dir():
    raise SystemExit(f"Omarchy's shell modules are not at {SHELL}; set OMARCHY_SHELL")

failures: list[str] = []
checks = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global checks
    checks += 1
    if ok:
        print(f"ok   {name}")
    else:
        failures.append(name)
        print(f"FAIL {name}" + (f": {detail}" if detail else ""))


# ---- the runtime harness ----------------------------------------------------

env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
env.pop("WAYLAND_DISPLAY", None)
env.pop("DISPLAY", None)
# Omarchy sets QT_QPA_PLATFORMTHEME=gtk3, and that theme opens a GTK display of
# its own even under offscreen; with no display it fails and the harness dies
# before printing a check.
env.pop("QT_QPA_PLATFORMTHEME", None)

with tempfile.TemporaryDirectory(prefix="pi-presence-qml-") as directory:
    harness = Path(directory)
    shutil.copy(ROOT / "tests/qml/shell.qml", harness / "shell.qml")
    shutil.copy(PLUGIN / "Model.js", harness / "Model.js")
    shutil.copytree(PLUGIN / "i18n", harness / "i18n")
    # The bar widget and the popup under other names: both extend qs.Ui types,
    # and a file of the same name beside them would resolve that name to itself.
    shutil.copy(PLUGIN / "BarWidget.qml", harness / "BarPanel.qml")
    shutil.copy(PLUGIN / "Panel.qml", harness / "PresencePanel.qml")
    (harness / "Commons").symlink_to(SHELL / "Commons")
    # qs.Ui as Omarchy ships it, but for the popups: a layer-shell window has no
    # backend offscreen, so plain Items with the same properties take their place.
    shutil.copytree(SHELL / "Ui", harness / "Ui", symlinks=True)
    # The stubs replace real files, and the tree above is symlinked: writing
    # through the symlink would hit the read-only system copy, so unlink first.
    for stub in ("PopupCard.qml", "KeyboardPanel.qml"):
        (harness / "Ui" / stub).unlink()
        shutil.copy(ROOT / "tests/qml" / stub, harness / "Ui" / stub)
    # Quickshell keeps per-instance state in the runtime directory; a private one
    # also works where the session has none (CI containers).
    runtime = harness / "runtime"
    runtime.mkdir(mode=0o700)
    env["XDG_RUNTIME_DIR"] = str(runtime)

    shell = subprocess.Popen(["quickshell", "-p", str(harness)], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, env=env)
    timer = threading.Timer(30, shell.kill)
    timer.start()
    lines: list[str] = []
    for line in shell.stdout:
        lines.append(line)
        if re.search(r"qml:\s+(ALL OK|\d+ FAILED)", re.sub(r"\x1b\[[0-9;]*m", "", line)):
            break
    timer.cancel()
    shell.kill()
    shell.wait()
    output = "".join(lines)

plain = re.sub(r"\x1b\[[0-9;]*m", "", output)
runtime_checks = re.findall(r"qml:\s+(ok|FAIL)\s+(.*?)\s*$", plain, re.MULTILINE)
failed = [name for state, name in runtime_checks if state == "FAIL"]

check("the harness produced checks", bool(runtime_checks), plain[-2000:])
# Name what broke before complaining the run was incomplete: a failed check is
# the useful message, and it is also why the run did not reach "ALL OK".
check("no runtime check failed", not failed, "; ".join(failed))
check("the harness finished", "ALL OK" in plain, plain[-2000:])
# QML reports binding and type errors as warnings, and a widget that loads with
# an unbound property prints them without failing a single check above.
noise = [line for line in plain.splitlines()
         if re.search(r"is not defined|Cannot assign|is not a member|Type .* unavailable"
                      r"|is a required property|QtQuick.*no such", line)]
check("QML raised no binding errors", not noise, "\n".join(noise[:8]))

checks += len(runtime_checks)

# ---- the font ---------------------------------------------------------------

BAR_FONT_FALLBACKS = [
    "/usr/share/fonts/TTF/JetBrainsMonoNL-Regular.ttf",
    "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
]


def bar_font() -> Path | None:
    try:
        out = subprocess.run(
            ["fc-match", "-f", "%{file}",
             f"family={os.environ.get('OMARCHY_BAR_FONT_FAMILY', 'monospace')}:style=Regular"],
            capture_output=True, text=True, check=True).stdout.strip()
    except subprocess.CalledProcessError:
        return None
    path = Path(out)
    if path.is_file():
        return path
    for candidate in BAR_FONT_FALLBACKS:
        if Path(candidate).is_file():
            return Path(candidate)
    return None


def cmap(path: Path) -> set[int]:
    """Codepoints the font covers, from its cmap table (format 4 and 12)."""
    data = path.read_bytes()
    if data[:4] != b"\x00\x01\x00\x00" and data[:4] != b"true":
        return set()
    num = struct.unpack(">H", data[4:6])[0]
    tables = {}
    for i in range(num):
        off = 12 + i * 16
        tag = data[off:off + 4].decode("latin-1")
        tables[tag] = struct.unpack(">II", data[off + 8:off + 16])
    if "cmap" not in tables:
        return set()
    start = tables["cmap"][0]
    cmap_bytes = data[start:]
    count = struct.unpack(">H", cmap_bytes[2:4])[0]
    found: set[int] = set()
    for i in range(count):
        rec = 4 + i * 8
        sub = struct.unpack(">II", cmap_bytes[rec + 4:rec + 12])[0]
        fmt = struct.unpack(">H", cmap_bytes[sub:sub + 2])[0]
        if fmt == 4:
            seg = struct.unpack(">H", cmap_bytes[sub + 6:sub + 8])[0] // 2
            ends = struct.unpack(f">{seg}H", cmap_bytes[sub + 14:sub + 14 + seg * 2])
            starts = struct.unpack(f">{seg}H", cmap_bytes[sub + 16 + seg * 2:sub + 16 + seg * 4])
            deltas = struct.unpack(f">{seg}h", cmap_bytes[sub + 18 + seg * 4:sub + 18 + seg * 6])
            ranges = struct.unpack(f">{seg}H", cmap_bytes[sub + 18 + seg * 6:sub + 18 + seg * 8])
            for s, e, d, r in zip(starts, ends, deltas, ranges):
                for cp in range(s, min(e, 0xFFFF) + 1):
                    if r == 0:
                        if (cp + d) & 0xFFFF:
                            found.add(cp)
                    else:
                        addr = sub + r + (cp - s) * 2
                        gid = struct.unpack(">H", cmap_bytes[addr:addr + 2])[0]
                        if gid:
                            found.add(cp)
        elif fmt == 12:
            n = struct.unpack(">I", cmap_bytes[sub + 12:sub + 16])[0]
            for i in range(n):
                rec = sub + 16 + i * 12
                s, e, g = struct.unpack(">III", cmap_bytes[rec:rec + 12])
                if g:
                    found.update(range(s, e + 1))
    return found


def model_js(name: str) -> str:
    return (PLUGIN / "Model.js").read_text()


def export_from(name: str) -> dict:
    """Pull a JS literal table out of Model.js, without a JS engine.

    The tables are `var NAME = { key: value, … }` with trailing comments, so
    they are not JSON: keys are bare and the glyph values are hex.
    """
    body = model_js(name)
    match = re.search(rf"var {name} = \{{(.*?)\n\}};", body, re.DOTALL)
    if not match:
        raise SystemExit(f"Model.js: cannot find var {name}")
    out: dict[str, object] = {}
    for key, raw in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)(?:,\s*(?://[^\n]*)?|\s*//[^\n]*|\s*$)",
                                match.group(1)):
        value = raw.strip()
        if value.startswith('"') and value.endswith('"'):
            out[key] = value[1:-1]
        elif value.startswith("0x"):
            out[key] = int(value, 16)
        elif value:
            out[key] = value
    return out


GLYPHS = export_from("GLYPHS")
LABELS = export_from("LABELS")

font = bar_font()
check("the bar font resolves", font is not None,
      f"OMARCHY_BAR_FONT_FAMILY={os.environ.get('OMARCHY_BAR_FONT_FAMILY', '<unset>')}")
if font is not None:
    covered = cmap(font)
    check("the bar font's cmap parsed", bool(covered), font.as_uri())
    missing = sorted(f"U+{cp:05X} {label}" for label, cp in GLYPHS.items() if cp not in covered)
    # A missing codepoint is a tofu box in the bar, not a crash: this is the
    # check that catches it.
    check(f"every glyph is in {font.name}", not missing, "; ".join(missing))

# Material Design Icons codepoints, from the icon set's own metadata. Pinned
# here so the glyph names in Model.js stay true offline: a codepoint guessed from
# the list's order renders as some other icon, and the cmap check above cannot see
# that — it only proves the codepoint is a glyph, not which one.
GLYPH_NAMES = {
    "bar": ("pi", 0xF03FF),
    "barLive": ("pi-box", 0xF0400),
    "thinking": ("brain", 0xF09D1),
    "tool": ("wrench", 0xF05B7),
    "bash": ("console-line", 0xF07B7),
    "editing": ("pencil", 0xF03EB),
    "reading": ("eye", 0xF0208),
    "searching": ("magnify", 0xF0349),
    "browsing": ("open-in-new", 0xF03CC),
    "delegating": ("robot-outline", 0xF167A),
    "planning": ("clipboard-list", 0xF10D4),
    "asking": ("help-circle", 0xF02D7),
    "waiting": ("clock-alert-outline", 0xF05CE),
    "compacting": ("progress-clock", 0xF0996),
    "done": ("check-circle", 0xF05E0),
    "idle": ("circle-outline", 0xF0766),
    "error": ("alert-circle", 0xF0028),
    "jump": ("open-in-new", 0xF03CC),
    "refresh": ("refresh", 0xF0450),
    "close": ("close", 0xF0156),
}
for key, (name, code) in GLYPH_NAMES.items():
    check(f"the {key} glyph is {name} U+{code:05X}", GLYPHS.get(key) == code,
          f"GLYPHS[{key}]=0x{GLYPHS.get(key, 0):05X}")

# ---- the files ------------------------------------------------------------

qml_files = ["Panel.qml", "Service.qml"]
for name in qml_files:
    text = (PLUGIN / name).read_text()
    texts = len(re.findall(r"\bText\s*\{|\bText\.$", text, re.MULTILINE))
    plain = len(re.findall(r"textFormat: Text\.PlainText", text))
    rich = len(re.findall(r"Text\.RichText|Text\.StylizedText|contentItem: \w*Rich", text))
    # The plugin renders text a tool can influence: model names, cwd, tool
    # subjects, bubble threads, notification bodies. Plain text is the boundary:
    # markup-shaped input has to render as the literal text it is.
    check(f"{name}: text sinks are all plain text", plain >= texts and rich == 0,
          f"{plain} plain-text sinks for {texts} Text elements, {rich} rich")

panel = (PLUGIN / "Panel.qml").read_text()
check("the widget watches the registry for changes", "watchChanges: true" in panel)
check("the widget reloads on change", "onFileChanged: statusFile.reload()" in panel)
check("the widget reads sessions.json", "sessions.json" in panel)
jump = panel[panel.index("function jump(session)"):]
check("the widget closes before it focuses",
      jump.index("root.close()") < jump.index("Qt.callLater"))
check("the popup is keyboard driven", "PanelKeyCatcher" in panel)
check("the bar icon is the pi symbol, boxed when working",
      (GLYPHS["bar"], GLYPHS["barLive"]) == (0xF03FF, 0xF0400))

service = (PLUGIN / "Service.qml").read_text()
check("the service reads the same registry", "sessions.json" in service)
check("the service restores the baseline", "restoreIdle" in service and "hl.config" in service)
check("the service mirrors its baseline", "border-baseline.json" in service)

manifest = json.loads((PLUGIN / "manifest.json").read_text())
check("the manifest is schema version 1", manifest.get("schemaVersion") == 1)
check("the manifest id is pi.presence", manifest.get("id") == "pi.presence")
for kind in manifest.get("kinds", []):
    entry = manifest.get("entryPoints", {}).get("service" if kind == "service" else "barWidget")
    check(f"{kind} entry point exists: {entry}", bool(entry) and (PLUGIN / entry).is_file())
# The collapsible zone is the tray's drawer, which the bar fills from
# .bar.layout.tray; "right" is the fixed part of the bar, outside that drawer.
check("the widget defaults to the tray drawer",
      manifest.get("barWidget", {}).get("defaultSection") == "tray")
INSTALLER = ROOT / "install.sh"
if not INSTALLER.exists():                       # the Dotfiles copy
    INSTALLER = ROOT.parent / "scripts" / "pi-presence-sync"
installer = INSTALLER.read_text()
# Spacing and shell escaping differ between the standalone installer and the
# Dotfiles sync script; the jq filter is the same, so compare it flattened.
flat = re.sub(r"[\\\s]+", "", installer)
check("the installer places the widget in the tray drawer",
      '.tray=(["pi.presence"]+(.tray|strip_id))' in flat, INSTALLER.name)
check("the installer strips the widget from the fixed bar",
      '.right=(.right|strip_id)' in flat, INSTALLER.name)
check("the service stays loaded", manifest.get("keepLoaded") is True)
symlinks = [p for p in ROOT.rglob("*") if p.is_symlink()]
check("no symlinks in the plugin", not symlinks, ", ".join(str(p) for p in symlinks))

# Every state the pi extension can publish must be known to the widget, or the
# row shows a fallback label and an unrelated glyph.
EXT = ROOT / "extension" / "omarchy-presence.ts"
if not EXT.exists():                            # the Dotfiles copy
    EXT = ROOT.parent / "pi" / "agent" / "extensions" / "omarchy-presence.ts"
extension = EXT.read_text()
published = set(re.findall(r'publish\("([a-z_]+)"', extension))
unknown = sorted(published - set(LABELS))
check("every published state has a label", not unknown, ", ".join(unknown))
check("the extension publishes to the registry the widget reads",
      "sessions.json" in extension and "sessions.json" in panel)
check("the extension has no osd bubbles", ".osd(" not in extension,
      "the bar is the indicator; per-tool notifications were asked for to stop")
check("the presence command summons through the bar",
      '"shell", "toggle"' in extension.replace("\n", " ").replace("  ", " "),
      "summon route")
check("the notification jumps by window address",
      "hl.dsp.focus({ window = " in extension and "address:" in extension)

# ---- focus, live -----------------------------------------------------------
# The last check runs against the machine: it needs Hyprland, so it is skipped
# offscreen and is real where the plugin is installed.
if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
    registry = Path(os.environ["HOME"]) / ".cache/pi-presence/sessions.json"
    if registry.is_file():
        frame = json.loads(registry.read_text())
        check("the live registry is version 2", frame.get("v") == 2, str(frame.get("v")))
        check("the live registry carries the host",
              all(s.get("host") for s in frame.get("sessions", [])),
              json.dumps([s.get("host") for s in frame.get("sessions", [])]))
        check("every live session has a state",
              all(s.get("state") in LABELS for s in frame.get("sessions", [])))
    else:
        print("skipped live registry check: no sessions.json yet")
else:
    print("skipped live registry check: not a Hyprland session")


# ---- the marketplace contract ----------------------------------------------
# https://plugins.omarchy.org/publish.html — what the listing validation looks
# at. Checked here so a push that would be rejected upstream fails locally.
check("manifest.json is at the repository root", (ROOT / "manifest.json").is_file())
check("README is at the repository root", (ROOT / "README.md").is_file())
check("LICENSE is at the repository root", (ROOT / "LICENSE").is_file())
for key in ("schemaVersion", "id", "name", "version", "author", "description",
            "kinds", "entryPoints"):
    check(f"the manifest has {key}", manifest.get(key) not in (None, "", []))
entry_points = manifest.get("entryPoints", {})
check("schemaVersion is 1", manifest.get("schemaVersion") == 1)
check("the id is namespaced", re.fullmatch(r"[a-z0-9]+(\.[a-z0-9]+)+", manifest.get("id", "")))
check("the id is not under omarchy.*", not manifest.get("id", "").startswith("omarchy."),
      "third-party ids cannot use the omarchy namespace")
check("the version is semver", re.fullmatch(r"\d+\.\d+\.\d+", manifest.get("version", "")))
# The kind table in the development guide: each kind needs its entry point key.
KIND_KEY = {"bar-widget": "barWidget", "panel": "panel", "overlay": "overlay",
            "menu": "menu", "service": "service", "bar": "bar"}
for kind in manifest.get("kinds", []):
    key = KIND_KEY.get(kind)
    check(f"kind {kind} has entryPoints.{key}", key is not None and key in entry_points,
          f"kinds={manifest.get('kinds')} entryPoints={list(entry_points)}")
    target = entry_points.get(key)
    file = ROOT / target
    check(f"{kind} entry point {target} exists",
          target is not None and file.is_file(), str(target))
    check(f"{target} is a safe relative path",
          target is not None and not target.startswith("/") and ".." not in Path(target).parts,
          str(target))
check("the panel is not a second kind, it is loaded by the bar widget",
      "panel" not in manifest.get("kinds", []),
      "the development guide: the bar widget's Loader loads Panel.qml; do not declare a panel kind")
# Safe install and removal.
check("the installer can uninstall", "--uninstall" in installer, INSTALLER.name)
check("the installer never uses sudo", "sudo" not in installer, INSTALLER.name)
# Everything it touches is under $HOME: the plugin dir, the extension dir, the
# shell config, the cache. No system paths, no privilege escalation.
abs_paths = re.findall(r"(?:cp|mv|rm -rf|mkdir -p)\s+/[^\s]+", installer)
check("the installer touches no absolute paths", not abs_paths, " ".join(abs_paths))
check("preview.png is present for the marketplace card", (ROOT / "preview.png").is_file())

if failures:
    print(f"\n{len(failures)} FAILED of {checks}")
    sys.exit(1)
print(f'\n{{"checks": {checks}, "failed": 0}}')

