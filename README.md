# pi.presence

One **π** on the right of the [Omarchy](https://omarchy.org) bar, in the tray drawer. Click it
and a panel drops down listing every running [pi](https://pi.dev) session — the
project, what it is doing right now (`executing bash`, `editing`, `asking a
question`, `waiting for you`), a thread of its recent bubbles, and a **Jump**
button that focuses that session's terminal.

The window border tells the story from across the room: it swells to a rotating
accent gradient while an agent works, goes solid urgent when one waits for you,
and returns to the theme baseline when everything is idle.

```
                    π 3                            in the tray drawer, right
        ┌────────────────────────────────────────────┐
        │ Pi sessions                              3   │
        │ ─────────────────────────────────────────── │
        │ 󰋗  Notes            asking a question   2s  [jump]
        │      ◦ asking a question
        │ 󰞷  Dotfiles         executing bash       1s  [jump]
        │      ◦ thinking
        │      ◦ editing · Panel.qml
        │      ◦ executing bash · omarchy plugin validate
        │      qwen3.8 · 12 tools · 50s
        │ 󰏿 idle · Dotfiles                   4s   [jump]
        └────────────────────────────────────────────┘
```

## Install

```bash
git clone <your-remote> ~/Work/pi-presence
cd ~/Work/pi-presence
./install.sh
```

`install.sh` copies the plugin into `~/.config/omarchy/plugins/pi-presence`,
validates it, puts the widget first in the bar's right section, installs the pi
extension into `~/.pi/agent/extensions/`, and restarts the shell.

| flag | effect |
| --- | --- |
| `--dry-run` | print what would happen, change nothing |
| `--no-restart` | install, leave the running shell alone |
| `--uninstall` | remove the plugin, its bar slot, and the extension |

Requires Omarchy (Quickshell + Hyprland) and `jq`.

Two things a symlink cannot do here, which is why there is a script:

* Omarchy's plugin validator rejects symlinks inside a plugin folder, so the
  plugin is copied.
* Quickshell has no config hot reload — without a shell restart the bar keeps the
  QML it loaded at boot.

`pi` picks up the extension on its **next start**, never in a running session.

## How it works

```
pi process A ─┐
pi process B ─┼─► ~/.cache/pi-presence/sessions.json ─► FileView ─► Panel.qml
pi process C ─┘        (registry, v2)                              └► Service.qml
```

* **The extension** (`extension/omarchy-presence.ts`) is the only thing that
  knows what pi is doing. It claims a slot in the registry keyed by pid, writes
  on every tool event, beats every 5 s, and forgets its slot on exit. A pi that
  is killed (no exit event) drops out after 20 s of silence, checked against
  `/proc`.
* **Concurrent writers** take an `mkdir` lock — atomic on any POSIX
  filesystem — with a stale-lock timeout, and the JSON is written **in place**,
  never by rename: the panel's `FileView` watches that inode, and a rename moves
  the inode out from under it.
* **The widget** (`plugin/BarWidget.qml`) is a `Ui/BarWidget.qml`, and it hosts
  `plugin/Panel.qml` — a `Ui/Panel.qml` — through a `Loader`, injecting `bar`,
  `settings` and `anchorItem` exactly as Omarchy's own clock widget does. This is
  the shape the bar understands: a nested panel is `manageIpc: false` and is
  opened by the bar (`shell.togglePanelAt right 0`), because a `PopupCard` in
  click mode takes a `HyprlandFocusGrab`, which needs a pointer serial that an
  IPC open cannot supply — it then silently refuses to map.
* **The service** (`plugin/Service.qml`) drives Hyprland through `hyprctl eval`:
  `general:border_size`, `general:col.active_border`, and the `borderangle`
  animation. It captures the theme's baseline on first run and mirrors it to
  `~/.cache/pi-presence/border-baseline.json`, so it can hand it back — including
  after a shell restart, and on uninstall.

## Security

Everything in the panel is text that came out of a tool, a model, a directory
name, or a window title. None of it is trusted by this UI:

* every text sink is `Text.PlainText` — no markup, no link, no resource
  fetching, from content that can contain `<img src=…>`;
* every string is sanitised at the boundary: control characters stripped,
  whitespace collapsed, length capped;
* the Hyprland window address is matched as `0x[0-9a-f]+` and the focused window
  is addressed by that token alone — `0x55e5; rm -rf /` becomes `0x55e5`;
* the Jump button runs argv directly (`hyprctl dispatch …`), never through a
  shell, so there is nothing to quote;
* the panel is keyboard-driven, so keyboard navigation moves a single cursor,
  clamped to the rows that exist.

## Use

| | |
| --- | --- |
| click the π | open the sessions panel |
| `↑` `↓` | move between sessions |
| `Enter` / `j` | jump to the selected session's terminal |
| `r` | re-read the registry |
| `Esc` | close |
| `/presence` (inside pi) | report sessions, summon the panel |
| `omarchy-shell pi.presence open` | summon the panel |
| `omarchy-shell shell.togglePanelAt right 0` | the canonical route the bar itself uses |

Jump closes the panel first: the panel holds a focus grab, and a focus request
made under it goes nowhere. It focuses by window address, falling back to
`omarchy-hyprland-focus-app <app-id>` when the window is gone (the terminal
closed, the session moved).

## States

`off` `idle` `thinking` `tool` `bash` `editing` `reading` `searching`
`browsing` `delegating` `planning` `asking` `waiting` `compacting` `done`
`error`

Each has a label, a colour tone (muted, foreground, accent, urgent) and a Nerd
Font glyph. The bar font is resolved from `OMARCHY_BAR_FONT_FAMILY`; the test
suite reads that font's cmap and fails if a glyph is missing.

## Test

```bash
python3 tests/model_contract.py
```

80 checks, in three layers:

1. **runtime** — `quickshell` under `QT_QPA_PLATFORM=offscreen`, loading the real
   widget and the real panel, fed a registry with sessions in three states: sort
   order, staleness, torn reads (which must keep the last frame), an empty
   registry (which must clear the bar), sanitisation, glyph coverage, the jump
   argv, cursor clamping.
2. **static** — every text sink in the QML is plain text; the popup is
   keyboard-driven and anchored to the injected button; the widget hosts the panel
   through a `Loader` and forwards the panel contract; no symlinks.
3. **live** — against the running registry, when a pi is running: version, host,
   states.

`deno fmt --check && deno lint` covers the extension.

## Files

```
install.sh
plugin/    manifest.json BarWidget.qml Panel.qml Service.qml Model.js i18n/en.json
extension/ omarchy-presence.ts
tests/     model_contract.py qml/{shell,PopupCard,KeyboardPanel}.qml
```

`tests/qml/{PopupCard,KeyboardPanel}.qml` are offscreen stand-ins: layer-shell
popups have no backend without a compositor, so plain Items with the same
properties and content contract stand in, and the real content is instantiated.

## Uninstall

```bash
./install.sh --uninstall
```

Removes the plugin, the extension, and the widget's bar slot. Leaves
`~/.cache/pi-presence/`, which holds the border baseline the service restored.

## License

MIT
