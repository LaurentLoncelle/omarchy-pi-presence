#!/usr/bin/env bash
# Validate before submitting to the marketplace.
#
# The marketplace checks the current commit of a public repository: a manifest at
# the root, a README, a license, safe install and removal. This runs the same
# checks locally, and the plugin's own contract suite on top.
#
#   ./check.sh              validate, then run the suite
#   ./check.sh --quick     manifest and files only
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

fail=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
ok() { printf '  ok   %s\n' "$1"; }
no() { printf '  FAIL %s\n' "$1"; fail=1; }
skip() { printf '  --   %s\n' "$1"; }

# The standalone repository is the submission. The same plugin inside a dotfiles
# collection keeps its README, LICENSE and installer at the collection root, so
# only the manifest and the sources are checked there.
standalone=1
[[ -f install.sh ]] || standalone=0

echo "repository"
for f in manifest.json BarWidget.qml Panel.qml Service.qml Model.js; do
  [[ -f "$f" ]] && ok "$f" || no "$f is required"
done
if [[ $standalone -eq 1 ]]; then
  for f in README.md LICENSE preview.png; do
    [[ -f "$f" ]] && ok "$f" || no "$f is missing (preview.png: run tests/make_preview.py)"
  done
else
  skip "README.md LICENSE preview.png" "the dotfiles copy: they live at the collection root"
fi

if grep -q '\.symlink\|symlink:' manifest.json 2>/dev/null; then
  no "the manifest must not reference symlinks"
fi
if find . -type l -not -path './.git/*' | grep -q .; then
  no "symlinks in the plugin: $(find . -type l -not -path './.git/*' | tr '\n' ' ')"
else
  ok "no symlinks"
fi

echo
echo "manifest"
if command -v omarchy >/dev/null 2>&1; then
  if omarchy plugin validate "$HERE" >/dev/null 2>&1; then
    ok "omarchy plugin validate"
  else
    no "omarchy plugin validate"
    omarchy plugin validate "$HERE" 2>&1 | sed 's/^/       /' | head -12
  fi
else
  skip "omarchy not installed: checked the manifest fields only"
  python3 - "$HERE/manifest.json" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
required = ["schemaVersion", "id", "name", "version", "author", "description",
            "kinds", "entryPoints"]
for key in required:
    if key not in m:
        print(f"  FAIL manifest has no {key}"); sys.exit(1)
if m["schemaVersion"] != 1:
    print("  FAIL schemaVersion must be 1"); sys.exit(1)
if not re.fullmatch(r"[a-z0-9-]+\.[a-z0-9-]+", m["id"]):
    print(f"  FAIL id is not namespaced: {m['id']}"); sys.exit(1)
if not re.fullmatch(r"\d+\.\d+\.\d+", str(m["version"])):
    print(f"  FAIL version is not semver: {m['version']}"); sys.exit(1)
if len(str(m["version"])) > 64:
    print("  FAIL version is longer than 64 characters"); sys.exit(1)
for kind in m["kinds"]:
    key = {"bar-widget": "barWidget", "service": "service", "overlay": "overlay",
           "panel": "panel"}.get(kind, kind)
    if key not in m["entryPoints"]:
        print(f"  FAIL kind {kind} has no entry point"); sys.exit(1)
print("  ok manifest fields")
PY
fi

echo
echo "installer"
if [[ $standalone -eq 0 ]]; then
  skip "install and removal" "pi-presence-sync syncs; install.sh installs and uninstalls"
else
  grep -q "sudo" install.sh && no "the installer must not use sudo" || ok "no sudo"
  grep -q -- "--uninstall" install.sh && ok "removal is supported" || no "no --uninstall"
  bash -n install.sh && ok "the installer parses" || no "the installer does not parse"
fi

if [[ "${1:-}" == "--quick" ]]; then
  echo; [[ $fail -eq 0 ]] && echo "ready to submit" || echo "not ready"
  exit $fail
fi

echo
echo "registry permissions"
# sessions.json carries prompt text, shell command lines, the tails of tool
# output, absolute paths and hostnames. Node's modes are umask-masked and a mode
# on an existing path is ignored, so the writes must set them and chmod them:
# under the common 022 umask a bare writeFileSync leaves the registry 0644, and
# on a home that is group- or other-traversable that is a copy of every session
# for every local account, plus an attacker-writable cache dir for the symlink
# that becomes the registry.
ext=extension/omarchy-presence.ts
grep -q "const DIR_MODE = 0o700" "$ext" && grep -q "const FILE_MODE = 0o600" "$ext" \
  && ok "private modes declared (0700 dir, 0600 file)" \
  || no "$ext declares no private mode constants for the cache"
grep -q "writeFileSync(REGISTRY_FILE, JSON.stringify(registry), { mode: FILE_MODE })" "$ext" \
  && ok "the registry write sets a mode" \
  || no "the registry write has no mode argument"
grep -q "chmodSync(REGISTRY_FILE, FILE_MODE)" "$ext" \
  && ok "the registry is chmod 0600 on every write" \
  || no "no chmod of the registry: a file left 0644 by an older build stays 0644"
grep -q "function ensurePrivateDir" "$ext" \
  && grep -q "mkdirSync(path, { recursive: true, mode: DIR_MODE })" "$ext" \
  && grep -q "chmodSync(path, DIR_MODE)" "$ext" \
  && ok "the cache dir is created 0700 and chmod 0700 (ensurePrivateDir)" \
  || no "the cache dir is not created 0700, or the chmod is missing: umask decides"
grep -q "ensurePrivateDir(CACHE_DIR)" "$ext" \
  && ok "the write paths go through ensurePrivateDir" \
  || no "no write path calls ensurePrivateDir(CACHE_DIR)"
if grep -q "mkdirSync(CACHE_DIR" "$ext"; then
  no "a direct mkdirSync(CACHE_DIR…) bypasses ensurePrivateDir"
else
  ok "no mkdir of the cache dir outside ensurePrivateDir"
fi
bare=$(grep -n "mkdirSync(" "$ext" | grep -v "mode: DIR_MODE" || true)
if [[ -n "$bare" ]]; then
  no "a mkdir with no mode: $(echo "$bare" | tr '\n' ' ')"
else
  ok "every mkdir sets 0700"
fi
bare=$(grep -n "writeFileSync(" "$ext" | grep -v "mode:" || true)
if [[ -n "$bare" ]]; then
  no "a write with no mode argument: $(echo "$bare" | tr '\n' ' ')"
else
  ok "every write sets a mode"
fi
grep -q "lstatSync" "$ext" \
  && ok "symlinks on the cache path are checked (lstat)" \
  || no "no lstat check: a symlink at the cache or registry path is written through"

grep -q "umask 077" Service.qml \
  && ok "the service's baseline write runs under umask 077" \
  || no "Service.qml writes the baseline under the inherited umask"
grep -q "chmod 600 '" Service.qml \
  && ok "the baseline file is chmod 600" \
  || no "the baseline file has no chmod"
if [[ $standalone -eq 1 ]]; then
  grep -q "chmod 700 \"\$CACHE_DIR\"" install.sh \
    && ok "the installer tightens an existing cache dir to 0700" \
    || no "the installer leaves a 0755 cache dir from an older install in place"
else
  skip "installer cache hardening" "the dotfiles copy has no install.sh"
fi

# Live check: what is actually on this disk right now.
dir="$HOME/.cache/pi-presence"
if [[ -e "$dir" ]]; then
  if [[ -L "$dir" ]]; then
    no "$dir is a symlink"
  else
    mode=$(stat -c '%a' "$dir")
    [[ $(( 8#$mode & 8#0077 )) -eq 0 ]] \
      && ok "$dir is $mode (no group/other access)" \
      || no "$dir is $mode: session data is reachable by other local accounts"
  fi
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    fm=$(stat -c '%a' "$f")
    [[ $(( 8#$fm & 8#0077 )) -eq 0 ]] \
      && ok "$(basename "$f") is $fm" \
      || no "$(basename "$f") is $fm: readable by group/other, and it holds prompts, command lines and tool output"
  done
  for l in "$dir" "$dir"/*.json; do
    [[ -L "$l" ]] && no "$l is a symlink: the registry has to be a real file the panel reads, not a link somebody plants" || true
  done
fi

# The same, on a filesystem: the extension's real write path, driven by hand
# against a throwaway $HOME under umask 022, with a symlink planted at the
# registry path and at the cache dir. This is the gate that saw the 0644 registry
# and the write-through-symlink, so it is the one that keeps them away.
if command -v node >/dev/null 2>&1; then
  if node tests/registry_permissions.mjs >"$tmp" 2>&1; then
    ok "registry_permissions (node): $(grep -c '^ok' "$tmp") checks"
  else
    no "registry_permissions (node)"
    grep '^FAIL' "$tmp" | sed 's/^/       /' | head -12
  fi
else
  skip "registry_permissions (node)" "node is not installed"
fi

echo
echo "version"
# The marketplace takes the version from the manifest and a submission has to bump
# it, so the bump is checked against HEAD rather than remembered.
new=$(python3 -c 'import json;print(json.load(open("manifest.json"))["version"])' 2>/dev/null || echo "")
old=$(git show HEAD:manifest.json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null || echo "")
if [[ -z "$new" ]]; then
  no "manifest.json has no readable version"
elif [[ -z "$old" ]]; then
  skip "the version has bumped from HEAD" "no manifest at HEAD"
elif [[ "$new" == "$old" ]]; then
  no "the version is still $old: bump it before submitting"
elif [[ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -1)" == "$new" ]]; then
  ok "$old → $new"
else
  no "the version went backwards: $old → $new"
fi

echo
echo "docs"
# The naming and data-path rules are the part of the system guide that names this
# plugin: the module name, the bar slot, the paths it writes, and the modes those
# paths must have. If they move without the docs, the docs mislead the next reader.
if [[ $standalone -eq 1 ]]; then
  for f in SECURITY.md docs/marketplace.md; do
    [[ -f "$f" ]] && ok "$f" || no "$f is missing"
  done
  grep -q "0600" README.md && grep -q "0700" README.md \
    && ok "the README states the cache modes" \
    || no "the README does not document the registry's modes"
  grep -q "pi\.presence" docs/marketplace.md \
    && ok "the docs name the bar slot" \
    || no "the docs do not name the bar slot (pi.presence, in .bar.layout.tray)"
  grep -q "\.cache/pi-presence" docs/marketplace.md \
    && ok "the docs list the data paths" \
    || no "the docs do not list the data paths"
  grep -q "2.2.1" docs/marketplace.md \
    && ok "the docs record the version the fix landed in" \
    || no "the docs do not record the version the fix landed in"
else
  skip "SECURITY.md docs/marketplace.md" "the dotfiles copy: the collection root has them"
fi

if [[ $standalone -eq 0 ]]; then
  echo
  echo "ready to submit (from the standalone repository)"
  exit $fail
fi

echo
echo "contract suite"
if python3 tests/model_contract.py; then
  ok "model_contract"
else
  no "model_contract"
fi

echo
echo "typescript"
if command -v deno >/dev/null 2>&1; then
  deno fmt --check extension/omarchy-presence.ts >/dev/null 2>&1 && ok "deno fmt" || no "deno fmt"
  deno lint extension/omarchy-presence.ts >/dev/null 2>&1 && ok "deno lint" || no "deno lint"
else
  skip "deno is not installed"
fi

echo
[[ $fail -eq 0 ]] && echo "ready to submit" || echo "not ready"
exit $fail
