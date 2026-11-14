# Security: the session registry is world-readable

Reported against pi.presence 2.2.0, fixed in 2.2.1.

To file upstream: https://github.com/thexperts/awesome-Pi/issues — the body is
this file; `gh` needs `gh auth login` first, so the issue is not filed from here.

## Summary

`extension/omarchy-presence.ts` publishes every live Pi session to
`~/.cache/pi-presence/sessions.json` with no file mode and no private directory
creation. Under the common `022` umask that is a `0755` directory and a `0644`
file, and the file contains prompt text, shell command lines, the tails of tool
output, absolute paths, hostnames, window classes and pids. On any account whose
home directory is traversable by group or other, every local user can read the
working contents of every Pi session on the machine.

`Service.qml` writes `border-baseline.json` the same way (`mkdir -p` plus a shell
redirect, inheriting the umask), and `install.sh` created nothing private either.

## Affected

* `extension/omarchy-presence.ts` — `writeRegistry()`, `withLock()` (the cache
  directory and the lock directory)
* `Service.qml` — `persistBaseline()`
* `install.sh` — no pass over a cache directory an earlier install left open

## Mechanism

Three Node and shell behaviours stack up:

1. `writeFileSync(path, data)` creates with mode `0666 & ~umask` — `0644` under
   the default `022` umask, world-readable.
2. `mkdirSync(dir, { recursive: true })` creates with `0777 & ~umask` — `0755`,
   traversable, so the path is walkable to the world-readable file.
3. The mode argument on both is **ignored when the path already exists**, and is
   umask-masked even when it is honoured. So passing a mode is not enough: an
   existing `0644` registry stays `0644` until something chmods it, and a fixed
   build leaves the file open on a machine that ran the old one.

Nothing in the plugin ever set a mode, so on the reported machine the state was:

```
drwx------ 700  /home/loncelll
drwxr-xr-x 755  /home/loncelll/.cache
drwxr-xr-x 755  /home/loncelll/.cache/pi-presence
-rw-r--r-- 644  /home/loncelll/.cache/pi-presence/sessions.json
-rw-r--r-- 644  /home/loncelll/.cache/pi-presence/border-baseline.json
-rw-r--r-- 644  /home/loncelll/.cache/pi-presence/status.json
```

The exposure is the content. `sessions.json` in its live state on this machine:

```json
{"v":2,"updated":…,"sessions":[{"cwd":"/home/loncelll/Work/pi-presence",
 "detail":"ls -ld ~/.cache ~/.cache/pi-presence …","state":"bash",
 "bubbles":[{"state":"bash","text":"executing bash · sed -n '30,60p;95,130p' …"},
            {"state":"reading","text":"reading · /home/loncelll/Work/pi-presence/Service.qml"}]}]}
```

That is the shape of what leaks: the `detail` of a bash tool is the command line,
`tool_execution_update` publishes the tail of the tool's output, and
`before_agent_start` publishes the prompt. Commands carry credentials routinely
(`aws … --secret-access-key`, `curl -H "Authorization: …"`, `psql "postgres://u:p@"`),
and tool output is file contents.

## Reproduction

Runs the extension's real write path (the pi import stubbed, the events driven by
hand) against a throwaway `$HOME` under `umask 022`:

```sh
node /tmp/presence-perm/run.mjs .   # harness, described below
```

| scenario | 2.2.0 | 2.2.1 |
| --- | --- | --- |
| fresh install | dir `0755`, registry `0644` | dir `0700`, registry `0600` |
| leftovers from 2.2.0 (dir `0755`, file `0644`) | stays `0755`/`0644` | `0700`/`0600` |
| symlink planted at `sessions.json` | **written through** — the target file is replaced with registry JSON | symlink removed, registry written as a private regular file |
| symlink planted at the cache directory | registry created inside the attacker's `0777` directory | refuses to publish, nothing written |

The two symlink cases are the second half of the report: a world-writable cache
directory (which the old mode made trivial, and which an attacker-supplied
`sessions.json.lock` sibling makes easy) plus a symlink at the watched path turns
every 300 ms heartbeat into an arbitrary file overwrite as the victim, and the
shell happily follows the link to render the attacker's JSON in the panel.

## Impact

* Local information disclosure: prompts, command lines, tool output, working paths,
  hostnames, usernames-in-paths, project names, of every Pi session, to any local
  account that can traverse the home directory (`0755` homes: containers, NFS,
  machines set up by installers that predate `HOME_MODE 0700`, shared service
  accounts). On this machine `HOME_MODE` is `0700` and the home is `0700`, so the
  direct audience is other processes of the same uid; the fix is the general one,
  because the plugin cannot know whose home it is in.
* Data integrity: the symlink cases let another account write the registry the
  panel renders and the service acts on (it drives Hyprland border state from it,
  and the panel's Jump button runs `hyprctl` with a class derived from it).

## Fix (2.2.1)

`extension/omarchy-presence.ts`

* `ensurePrivateDir(path)` — `lstat` first (a symlink or a non-directory in the
  cache path is refused, never followed), `mkdir -p` with `mode: 0o700`, then
  `chmod 0700` because a mode on an existing directory is ignored. Every write path
  goes through it; the lock directory is created `0700` too.
* `writeRegistry()` — writes with `{ mode: 0o600 }` **and** `chmodSync(REGISTRY_FILE,
  0o600)` after it, which is the call that repairs a registry an older build left
  at `0644`. A symlink at the registry path is unlinked, never written through.
* `hardenCacheParent()` — tightens `~/.cache` to `0700` when it is a real directory
  owned by this uid and is group- or other-traversable (XDG calls the cache
  private; it is the walkway to the registry).

`Service.qml` — `persistBaseline()` runs `umask 077` and then `chmod 700` on the
directory and `chmod 600` on the file.

`install.sh` — `harden_cache` tightens a cache directory and registry that an
earlier install left open, and refuses to chmod a symlink it does not own.

Gates, so it cannot regress: `check.sh` has a `registry permissions` section
(every `writeFileSync` carries a mode, every `mkdirSync` carries `0700`, the
registry is chmodded, `~/.cache` is lstat'd, the service uses `umask 077`, the
installer tightens, and a **live** check of the modes on disk right now) and
`tests/model_contract.py` checks the same in the source and on the machine.

## Verification

```
registry permissions
  ok   private modes declared (0700 dir, 0600 file)
  ok   the registry write sets a mode
  ok   the registry is chmod 0600 on every write
  ok   the cache dir is created 0700 and chmod 0700 (ensurePrivateDir)
  ok   the write paths go through ensurePrivateDir
  ok   no mkdir of the cache dir outside ensurePrivateDir
  ok   every mkdir sets 0700
  ok   every write sets a mode
  ok   symlinks on the cache path are checked (lstat)
  ok   the service's baseline write runs under umask 077
  ok   the baseline file is chmod 600
  ok   the installer tightens an existing cache dir to 0700
  ok   /home/…/.cache/pi-presence is 700 (no group/other access)
  ok   border-baseline.json is 600
  ok   sessions.json is 600
  ok   status.json is 600
```

`./check.sh` → 144 checks, 0 failures. The live registry keeps working: the shell
watches the same inode (`FileView` + `watchChanges`), the chmod does not change it.

## Mitigation for 2.2.0 users, before upgrading

```sh
chmod 700 ~/.cache ~/.cache/pi-presence && chmod 600 ~/.cache/pi-presence/*.json
```

## Disclosure

Reported by the plugin's author, found by the audit requested alongside the naming
and data-path fixes. Intended for the public tracker:
https://github.com/thexperts/awesome-Pi/issues
