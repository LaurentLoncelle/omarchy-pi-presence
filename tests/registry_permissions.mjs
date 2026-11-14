// pi.presence: the registry's modes, on a real filesystem.
//
// The plugin publishes prompts, shell command lines, the tails of tool output,
// paths and hostnames to ~/.cache/pi-presence/sessions.json, so that file has to
// be 0600 inside a 0700 directory, on every write. Two Node behaviours make that
// a real requirement rather than a formality: the mode passed to mkdir/writeFile
// is masked by the process umask, and it is ignored entirely for a path that
// already exists. So this drives the real extension — the pi import stubbed, the
// events called by hand — against a throwaway $HOME under `umask 022`, and checks
// the modes it finds on disk:
//
//   fresh install                 dir 0700, registry 0600
//   leftovers from 2.2.0        0755/0644 on disk, fixed by the first write
//   symlink at sessions.json    never written through
//   symlink at the cache dir    never followed: nothing published
//
//   node tests/registry_permissions.mjs [repo-root]

import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = process.argv[2] ?? dirname(dirname(fileURLToPath(import.meta.url)));
const SOURCE = join(REPO, "extension/omarchy-presence.ts");
const src = readFileSync(SOURCE, "utf8");

let failures = 0;
let checks = 0;
function check(name, ok, detail = "") {
  checks += 1;
  if (ok) {
    console.log(`ok   ${name}`);
  } else {
    failures += 1;
    console.log(`FAIL ${name}${detail ? `: ${detail}` : ""}`);
  }
}

const MODE = (p) => {
  try {
    return (statSync(p).mode & 0o777).toString(8);
  } catch {
    return null;
  }
};
const IS_LINK = (p) => {
  try {
    return lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
};

// The session the extension publishes: a prompt, a bash command carrying a
// credential, and the tool output that answers it. This is the content whose
// mode is the subject of the test.
const DRIVE = (ext) => `
import ext from ${JSON.stringify(ext)};
const on = {};
const api = {
  exec: async () => ({ code: 0, stdout: "", stderr: "", killed: false, truncated: false }),
  on: (name, handler) => { on[name] = handler; },
  registerCommand: () => {},
  ui: { setTitle: () => {}, notify: () => {} },
};
ext(api);
const ctx = {
  cwd: ${JSON.stringify("/home/dev/Work/payments")},
  model: { id: "anthropic/claude-opus-4.1" },
  sessionManager: {
    getSessionName: () => "rotate keys",
    getCwd: () => ${JSON.stringify("/home/dev/Work/payments")},
  },
  ui: api.ui,
};
await on.session_start({}, ctx);
await on.before_agent_start({ prompt: "rotate the production DB password and update ~/.aws/credentials" }, ctx);
await on.tool_execution_start({ toolName: "bash", args: { command: "aws secretsmanager get-secret-value --secret-id prod/db" } }, ctx);
await on.tool_execution_update({ toolName: "bash", partialResult: { stdout: "{\\"SecretString\\":\\"hunter2-supersecret\\"}" } }, ctx);
await new Promise((r) => setTimeout(r, 400));
await on.session_shutdown({}, ctx);
await new Promise((r) => setTimeout(r, 700));
`;

function scenario(name, prepare, assert) {
  console.log(`\n${name}   (umask 022)`);
  const home = mkdtempSync(join(tmpdir(), "pi-presence-home-"));
  const work = mkdtempSync(join(tmpdir(), "pi-presence-run-"));
  // A 0755 home is the exposure: 0700 hides everything, so the harness starts
  // from the traversable case the plugin cannot see or choose.
  chmodSync(home, 0o755);
  mkdirSync(join(home, ".cache"), { mode: 0o755 });
  chmodSync(join(home, ".cache"), 0o755);
  writeFileSync(join(work, "pi-stub.ts"), "export {};\n");
  const ext = join(work, "ext.ts");
  writeFileSync(ext, src.replace(/"@earendil-works\/pi-coding-agent"/g, '"./pi-stub.ts"'));
  const drive = join(work, "drive.mjs");
  writeFileSync(drive, DRIVE(ext));
  prepare(home);
  let stderr = "";
  try {
    execFileSync("bash", ["-c", `umask 022; node ${JSON.stringify(drive)}`], {
      env: { ...process.env, HOME: home, HYPRLAND_INSTANCE_SIGNATURE: "" },
      stdio: ["ignore", "pipe", "pipe"],
      encoding: "utf8",
    });
  } catch (error) {
    stderr = `${error.stderr ?? ""}${error.stdout ?? ""}`;
  }
  const cache = join(home, ".cache");
  const dir = join(cache, "pi-presence");
  const registry = join(dir, "sessions.json");
  assert({ home, cache, dir, registry, stderr });
  rmSync(home, { recursive: true, force: true });
  rmSync(work, { recursive: true, force: true });
}

scenario("fresh install, traversable home", () => {}, (p) => {
  check("~/.cache is tightened to 0700", MODE(p.cache) === "700", MODE(p.cache));
  check("the cache dir is 0700", MODE(p.dir) === "700", MODE(p.dir));
  check("the cache dir is a real directory", !IS_LINK(p.dir) && existsSync(p.dir));
  check("the registry is 0600", MODE(p.registry) === "600", MODE(p.registry));
  check("the lock dir is gone", !existsSync(`${p.registry}.lock`));
});

scenario("leftovers from 2.2.0 (dir 0755, registry 0644)", (home) => {
  mkdirSync(join(home, ".cache", "pi-presence"), { mode: 0o755 });
  chmodSync(join(home, ".cache", "pi-presence"), 0o755);
  writeFileSync(join(home, ".cache", "pi-presence", "sessions.json"),
    '{"v":2,"updated":0,"sessions":[]}\n');
  chmodSync(join(home, ".cache", "pi-presence", "sessions.json"), 0o644);
}, (p) => {
  check("the open directory is tightened to 0700", MODE(p.dir) === "700", MODE(p.dir));
  check("the world-readable registry is fixed to 0600", MODE(p.registry) === "600",
    MODE(p.registry));
});

scenario("symlink planted at the registry path", (home) => {
  mkdirSync(join(home, ".cache", "pi-presence"), { mode: 0o777 });
  chmodSync(join(home, ".cache", "pi-presence"), 0o777);
  writeFileSync(join(home, "target.txt"), "DO NOT OVERWRITE\n");
  symlinkSync(join(home, "target.txt"), join(home, ".cache", "pi-presence", "sessions.json"));
}, (p) => {
  check("the symlink target is untouched",
    (() => {
      try {
        return readFileSync(join(p.home, "target.txt"), "utf8") === "DO NOT OVERWRITE\n";
      } catch {
        return false;
      }
    })(),
    "the registry write followed the symlink");
  check("the registry is a regular file", existsSync(p.registry) && !IS_LINK(p.registry));
  check("the registry is 0600", MODE(p.registry) === "600", MODE(p.registry));
});

scenario("symlink planted at the cache dir", (home) => {
  mkdirSync(join(home, "evil"), { mode: 0o777 });
  chmodSync(join(home, "evil"), 0o777);
  symlinkSync(join(home, "evil"), join(home, ".cache", "pi-presence"));
}, (p) => {
  check("the cache symlink is not followed", !existsSync(join(p.home, "evil", "sessions.json")),
    "published into the attacker's directory");
  check("nothing is written beside it", !existsSync(join(p.home, ".cache", "pi-presence", "sessions.json")));
});

console.log(`\n${checks - failures} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
