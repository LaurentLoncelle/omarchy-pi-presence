#!/bin/bash
# Install pi.presence: the Omarchy shell plugin, the bar slot, and the pi
# extension.
#
#   ./install.sh              install, place the widget, restart the shell
#   ./install.sh --dry-run    print what would happen, change nothing
#   ./install.sh --no-restart install without restarting the shell
#   ./install.sh --uninstall  remove the plugin, the widget slot, the extension
#
# Why a script at all, rather than the symlinks the rest of a dotfiles repo
# uses:
#   * The Omarchy plugin validator rejects symlinks inside a plugin folder
#     ("symlinks are not allowed inside a plugin folder"), so the plugin has to
#     be copied into ~/.config/omarchy/plugins.
#   * Quickshell has no config hot reload. Without a shell restart the bar keeps
#     whatever QML it loaded at boot, and the widget keeps reporting the state it
#     had when the shell started.
#   * The pi extension is loaded at `pi` startup: edits land on the next launch,
#     never in a running session. There is nothing to restart in the shell for it.
#
# Layout of this project (the marketplace validates a manifest.json at the
# repository root, so the plugin is flat here and NOT nested in a subfolder):
#   manifest.json BarWidget.qml Panel.qml Service.qml Model.js i18n/
#                the plugin, exactly as installed
#   extension/   the pi extension, single file
#   tests/       contract test: the panel's model against the registry shape,
#                the plugin against the manifest schema, the bar font's cmap
#   preview.png  the marketplace card image, optional

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Copied file by file, so the extension, the tests, this installer and the
# docs do not end up inside the plugin folder.
RUNTIME=(manifest.json BarWidget.qml Panel.qml Service.qml Model.js i18n)
EXT_SRC="$HERE/extension/omarchy-presence.ts"

PLUGIN_DST="$HOME/.config/omarchy/plugins/pi-presence"
EXT_DST="$HOME/.pi/agent/extensions/omarchy-presence.ts"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
CACHE_DIR="$HOME/.cache/pi-presence"
MODULE="pi.presence"
# The tray's drawer, not the fixed bar. `omarchy.tray` is the expander, and the
# bar fills its drawer from .bar.layout.tray; an id in .bar.layout.right sits in
# the always-visible part of the bar, outside that drawer.
SECTION="tray"

DRY=0
RESTART=1
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --no-restart) RESTART=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h | --help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
do_() {
  if [[ "$DRY" == 1 ]]; then
    say "  would: $*"
  else
    "$@"
  fi
}

# The bar layout is user data: it is edited through jq on a copy, and only
# written back when it parses. A slot is either the bare module id or an object
# carrying it, so both shapes are handled — leaving the old one in place would
# put a second π in the bar.
bar_layout() {
  local mode="$1"
  if [[ ! -f "$SHELL_JSON" ]] || ! jq -e . "$SHELL_JSON" >/dev/null 2>&1; then
    say "  $SHELL_JSON is missing or unparseable: leaving the bar alone"
    return 0
  fi
  local filtered='def strip_id: map(select((if type == "string" then . else .id end) != "pi.presence"));'
  case "$mode" in
    add)
      if [[ "$(jq "[.bar.layout.tray[]? | (if type == \"string\" then . else (.id // \"\") end)]
                   | index(\"pi.presence\")" "$SHELL_JSON")" == "0" ]]; then
        say "  widget already first in the tray's drawer"
        return 0
      fi
      do_ bash -c "jq '$filtered
        .bar.layout |= (.left=(.left|strip_id) | .center=(.center|strip_id)
          | .centerBegin=(.centerBegin|strip_id) | .centerEnd=(.centerEnd|strip_id)
          | .right=(.right|strip_id) | .tray=([\"pi.presence\"]+(.tray|strip_id)))' \
          '$SHELL_JSON' > '$SHELL_JSON.tmp' && mv '$SHELL_JSON.tmp' '$SHELL_JSON'"
      say "  widget placed first in the tray's drawer"
      ;;
    remove)
      do_ bash -c "jq '$filtered .bar.layout |= (.left=(.left|strip_id) | .center=(.center|strip_id)
        | .centerBegin=(.centerBegin|strip_id) | .centerEnd=(.centerEnd|strip_id)
        | .tray=(.tray|strip_id) | .right=(.right|strip_id))' \
        '$SHELL_JSON' > '$SHELL_JSON.tmp' && mv '$SHELL_JSON.tmp' '$SHELL_JSON'"
      say "  widget removed from the bar layout"
      ;;
  esac
}

if [[ "$UNINSTALL" == 1 ]]; then
  say "uninstalling $MODULE"
  do_ rm -rf "$PLUGIN_DST"
  do_ rm -f "$EXT_DST"
  bar_layout remove
  # The cache is left alone by design: it is a snapshot of live sessions, and
  # deleting it would blank the border baseline the service restores on exit.
  say "left $CACHE_DIR in place (border baseline, session registry)"
  if [[ "$RESTART" == 1 ]] && command -v omarchy-restart-shell >/dev/null 2>&1; then
    do_ omarchy-restart-shell
    say "shell restarted"
  fi
  exit 0
fi

# ---- install ---------------------------------------------------------------

for tool in jq omarchy; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool is required (the installer validates the plugin and edits the bar layout)" >&2
    exit 1
  }
done
for f in "${RUNTIME[@]}"; do
  [[ -e "$HERE/$f" ]] || {
    echo "missing $HERE/$f — run this from inside the project" >&2
    exit 1
  }
done
[[ -f "$EXT_SRC" ]] || { echo "missing $EXT_SRC" >&2; exit 1; }

say "installing $MODULE from $HERE"

# Remove first: a leftover widget file is a second thing watching the same
# registry, and it renders whatever the last install had in it.
do_ rm -rf "$PLUGIN_DST"
do_ mkdir -p "$PLUGIN_DST"
for f in "${RUNTIME[@]}"; do
  do_ cp -a "$HERE/$f" "$PLUGIN_DST/"
done
say "  plugin  → $PLUGIN_DST"

do_ mkdir -p "$(dirname "$EXT_DST")"
if [[ -e "$EXT_DST" && $(readlink -f "$EXT_DST" 2>/dev/null || true) == "$(readlink -f "$EXT_SRC")" ]]; then
  say "  extension is already this file (symlinked dotfiles): nothing to copy"
elif [[ "$DRY" == 1 ]]; then
  say "  would: cp $EXT_SRC $EXT_DST"
else
  # Unlink first. cp onto an existing file writes through it, and a dotfiles
  # install hardlinks this file into ~/.pi: writing through the hardlink would
  # edit the repo's copy in place, and a symlink would write into the repo.
  rm -f "$EXT_DST"
  cp "$EXT_SRC" "$EXT_DST"
  say "  extension → $EXT_DST (pi loads it on the next start)"
fi

bar_layout add

if [[ "$DRY" == 0 ]]; then
  omarchy plugin validate "$PLUGIN_DST"
  say "  validated"
fi

if [[ "$RESTART" == 1 ]]; then
  if command -v omarchy-restart-shell >/dev/null 2>&1; then
    do_ omarchy-restart-shell
    say "  shell restarted"
  else
    say "  omarchy-restart-shell not found: restart the shell by hand"
  fi
fi

say ""
say "done. The pi sits in the tray drawer at the right of the bar: open the tray with"
say "the chevron, then click the π for the sessions panel."
say "Start a pi session to see it light up. Restart pi to load the extension."
say "Check: $HERE/tests/model_contract.py"
