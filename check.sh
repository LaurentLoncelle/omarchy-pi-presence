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
