# Publishing pi.presence

Notes on the two upstream contracts this plugin has to satisfy, and what the
gates in `check.sh` and `tests/model_contract.py` enforce. Kept here because the
upstream pages change and a rejected submission should not need them re-read.

* https://raw.githubusercontent.com/omarchylabs/omarchy/main/docs/system.md — the
  system naming and data-path rules.
* https://plugins.omarchy.org/publish.html — the marketplace submission rules.

## Names

Every name the plugin puts in front of a user, and the one file name the system
doc's naming rules apply to:

| thing | name |
| --- | --- |
| marketplace name, manifest `name`, widget `displayName` | `Pi presence` |
| manifest `id` | `pi.presence` |
| bar slot (`Quickshell.Bar` → `moduleName`, the id in `.bar.layout.tray`) | `pi.presence` |
| panel `moduleName` / `ipcTarget` | `pi.presence` |
| widget category | `Status` |
| bar glyph | `π` (U+03C0, the Greek letter) |
| the panel's open command | `omarchy-shell shell toggle pi.presence` |
| plugin directory | `~/.config/omarchy/plugins/pi-presence` |
| pi extension | `~/.pi/agent/extensions/omarchy-presence.ts` |
| Hyprland side | `hyprctl eval hl.config(...)` / `hl.dsp.focus({ window = "address:…" })` |
| the slash command | `/presence` |

The rule that matters is that the id, the slot, the IPC target, the toggle command
and the directory all agree, and the docs name them the same way the sources do —
`pi.presence` in the bar layout, `Pi presence` in the listing, `π` in the bar. The
manifest id is namespaced and is not under `omarchy.*`, which is the marketplace
namespace.

## Data paths

Everything the plugin writes is under `~/.cache/pi-presence`, and the directory is
`0700` with the files `0600`:

| path | mode | |
| --- | --- | --- |
| `~/.cache/pi-presence/` | `0700` | created private: `lstat` first, `mkdir` `0700`, then `chmod 0700` |
| `~/.cache/pi-presence/sessions.json` | `0600` | the registry: prompts, command lines, tool-output tails, paths, hostnames |
| `~/.cache/pi-presence/sessions.json.lock` | `0700` | the mkdir lock the writers serialise on |
| `~/.cache/pi-presence/border-baseline.json` | `0600` | the Hyprland border settings the service restores |
| `~/.cache/pi-presence/status.json` | `0600` | legacy, from before the registry. Nothing here reads it |

Code goes to `~/.config/omarchy/plugins/pi-presence/`, the extension to
`~/.pi/agent/extensions/omarchy-presence.ts`, and the bar layout is edited in
`~/.config/omarchy/shell.json` through `jq` on a copy. No system path, no sudo.

The modes are not decoration, and they are not inherited: Node applies the process
umask to the mode you pass to `mkdir`/`writeFile` and ignores the mode on a path
that already exists, so under the usual `022` umask the naive write leaves a
world-readable `sessions.json`. Any machine whose home directory is group- or
other-traversable — containers, NFS exports, homes whose mode was set by an old
installer — exposes every session on it. Hence an explicit `chmod` on every write,
an `lstat` before it, and a tightening pass in `install.sh`. See
`SECURITY.md` for the report and the reproduction.

## Version

The marketplace takes the version from `manifest.json` and a submission has to
bump it. Behaviour changes bump the patch level: 2.2.0 → 2.2.1 for the private
cache modes.

## The gate

```sh
./check.sh            # repository, manifest, installer, registry permissions,
                      # the QML contract suite, the extension's modes, the docs
./check.sh --quick   # everything that needs no quickshell
```

`check.sh` fails when `manifest.json` carries the version that is already at HEAD,
so the bump is part of submitting rather than a step to forget.
