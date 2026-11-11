import {
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
  mkdirSync,
  readFileSync,
  rmdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, hostname } from "node:os";
import { basename, join } from "node:path";

// omarchy-presence
//
// Publishes every live Pi session to the Omarchy shell, and nothing else.
//
// The bar carries one π icon (`pi.presence`), in the tray drawer. Clicking it
// opens a popup
// listing each running Pi session with a status bubble — "executing bash",
// "editing", "asking a question", "waiting for you" — and a Jump button that
// focuses that session's terminal.
//
// There is deliberately no OSD. A bubble on every tool call is noise: the
// popup carries the tool, its detail and the elapsed time, and the window's
// real Hyprland border swells while the agent works (the plugin's Service.qml
// draws that from the same file).
//
// State lives in one JSON file so any number of Pi processes in any number of
// terminals share one registry:
//
//     ~/.cache/pi-presence/sessions.json
//     { "v": 2, "updated": 1731000000000, "sessions": [ … ] }
//
// Each writer reads, edits its own entry, drops records whose pid is gone,
// and writes back under an mkdir lock (atomic on POSIX, stolen once stale, so
// a killed Pi cannot wedge the registry). The file is written in place rather
// than renamed, because the shell watches that inode with inotify: a rename
// over it does not raise a change event on the watched file.

export type PresenceState =
  | "off"
  | "idle"
  | "thinking"
  | "tool"
  | "bash"
  | "editing"
  | "reading"
  | "searching"
  | "browsing"
  | "delegating"
  | "planning"
  | "asking"
  | "waiting"
  | "compacting"
  | "done"
  | "error";

export interface Bubble {
  ts: number;
  state: PresenceState;
  text: string;
}

export interface SessionRecord {
  id: string;
  pid: number;
  host: string;
  cwd: string;
  project: string;
  name: string;
  state: PresenceState;
  tool: string;
  detail: string;
  model: string;
  address: string;
  klass: string;
  needsAttention: boolean;
  turn: number;
  tools: number;
  startedAt: number;
  updatedAt: number;
  bubbles: Bubble[];
}

interface Registry {
  v: number;
  updated: number;
  sessions: SessionRecord[];
}

const CACHE_DIR = join(homedir(), ".cache", "pi-presence");
export const REGISTRY_FILE = join(CACHE_DIR, "sessions.json");
const LOCK_DIR = `${REGISTRY_FILE}.lock`;
const LOCK_STALE_MS = 4000;
const LOCK_WAIT_MS = 1500;
const HEARTBEAT_MS = 5000;
// Coalesce the tool_execution_update firehose: the popup is a status display,
// not a terminal, and the shell repaints on every write.
const MIN_WRITE_MS = 300;
const BUBBLE_CAP = 8;
// A record quiet for this long belongs to a Pi that died without cleaning up;
// the popup drops it rather than offering a dead Jump target.
export const STALE_SESSION_MS = 20_000;

// Nerd Font pi glyph U+EB55: the bar icon and the window title agree on it.
const GLYPH = "\u{03c0}"; // π

const EDIT_TOOLS = new Set([
  "edit",
  "multi_edit",
  "multitask",
  "patch",
  "write",
  "str_replace",
  "create_file",
  "notebook_edit",
]);
const READ_TOOLS = new Set(["read", "cat", "open", "view", "ls", "dir"]);
const SEARCH_TOOLS = new Set([
  "grep",
  "glob",
  "find",
  "fd",
  "search",
  "ast_grep",
]);
const WEB_TOOLS = new Set([
  "web_search",
  "web_fetch",
  "fetch",
  "browser",
  "web_browse",
  "http",
]);
const AGENT_TOOLS = new Set([
  "task",
  "subagent",
  "agent",
  "swarm",
  "orchestrate",
  "todo",
]);
const PLAN_TOOLS = new Set(["plan", "enter_plan_mode", "exit_plan_mode"]);
// An ask tool questions the user from inside the run; a ctx.ui prompt is the
// host asking permission. The popup draws them the same way, so they share a
// state, but the bubble reads differently.
const ASK_TOOLS = new Set(["ask", "question", "ask_user", "ask_user_question"]);

export const STATE_LABELS: Record<PresenceState, string> = {
  off: "off",
  idle: "idle",
  thinking: "thinking",
  tool: "running tool",
  bash: "executing bash",
  editing: "editing",
  reading: "reading",
  searching: "searching",
  browsing: "browsing",
  delegating: "delegating",
  planning: "planning",
  asking: "asking a question",
  waiting: "waiting for you",
  compacting: "compacting context",
  done: "ready",
  error: "error",
};

// exec is only available once an event has handed over a context, so a stub has
// to exist for the calls that run before that. It never fires in practice, so
// its async is structural: the linter's require-await is silenced rather than
// worked around by dropping the ExtensionAPI type, which is what keeps the
// signature honest about what it returns.
// deno-lint-ignore require-await
let exec: ExtensionAPI["exec"] = async () => ({
  code: 1,
  stdout: "",
  stderr: "",
  killed: false,
  truncated: false,
});

/** Collapse whitespace, drop control characters, cap the length. Every string
 * the popup shows has been through here: tool arguments and model output are
 * untrusted text. */
export function clean(value: unknown, max = 90): string {
  // A structured value is not text: String({}) is "[object Object]", and that
  // is what the bubble showed for a bash run whose partial result was an
  // object. Objects go through textOf, which digs the text out of them.
  if (value === null || value === undefined) return "";
  if (typeof value === "object") return "";
  const s = String(value)
    // deno-lint-ignore no-control-regex
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return s.length > max ? `${s.slice(0, Math.max(1, max - 1))}…` : s;
}

/** The last `max` characters of a stream: live tool output scrolls, and the
 * tail is what is happening now. */
export function tail(value: unknown, max = 80): string {
  const s = clean(value, 4000);
  return s.length > max ? `…${s.slice(-(max - 1))}` : s;
}

/** A window title has to survive quoting on the way to Lua, so quotes go. */
function cleanTitle(value: unknown): string {
  return clean(value, 120).replace(/["`\\]/g, "");
}

const PRESENCE_MODULE_ID = "pi.presence";
function firstString(input: Record<string, unknown>, keys: string[]): string {
  for (const key of keys) {
    const value = input[key];
    if (typeof value === "string" && value.trim() !== "") return value;
  }
  return "";
}

/** One short phrase naming what a tool is about to do. */
export function toolSubject(toolName: string, args: unknown): string {
  const input = (args ?? {}) as Record<string, unknown>;
  const command = firstString(input, ["command", "cmd", "shell"]);
  const url = firstString(input, ["url", "uri", "website"]);
  const pattern = firstString(input, ["pattern", "query", "q", "glob"]);
  const path = firstString(input, [
    "path",
    "file",
    "file_path",
    "filename",
    "notebook_path",
  ]);
  const task = firstString(input, [
    "description",
    "prompt",
    "message",
    "subject",
    "title",
    "question",
  ]);
  const target = firstString(input, [
    "host",
    "server",
    "agent",
    "selector",
    "key",
  ]);

  if (command) return clean(command, 80);
  if (url) return clean(url.replace(/^https?:\/\//, ""), 80);
  if (pattern && path) return clean(`${pattern} in ${path}`, 80);
  if (pattern) return clean(pattern, 80);
  if (path) return clean(path, 80);
  if (task) return clean(task, 80);
  if (target) return clean(target, 80);
  return clean(toolName, 40);
}

/** The state the popup shows while a given tool runs. */
export function stateForTool(toolName: string): PresenceState {
  const name = String(toolName ?? "").toLowerCase();
  if (
    name === "bash" || name === "shell" || name === "exec" ||
    name === "terminal"
  ) return "bash";
  if (EDIT_TOOLS.has(name)) return "editing";
  if (SEARCH_TOOLS.has(name)) return "searching";
  if (READ_TOOLS.has(name)) return "reading";
  if (WEB_TOOLS.has(name)) return "browsing";
  if (AGENT_TOOLS.has(name)) return "delegating";
  if (PLAN_TOOLS.has(name)) return "planning";
  if (ASK_TOOLS.has(name)) return "asking";
  return "tool";
}

/** The human text inside a structured event payload. Tool results are objects
 * (content blocks, stdout fields, deltas) and the shape is the host's, not
 * this extension's, so it is dug for rather than assumed: a string, an array of
 * blocks, or one of the keys that carry text. Never String(), which would put
 * "[object Object]" in the bar. */
function textOf(value: unknown, max = 120): string {
  if (typeof value === "string") return clean(value, max);
  if (typeof value === "number" || typeof value === "boolean") {
    return clean(String(value), max);
  }
  if (Array.isArray(value)) {
    return clean(
      value
        .map((item) => textOf(item, max))
        .filter((part) => part !== "")
        .join(" "),
      max,
    );
  }
  if (typeof value !== "object" || value === null) return "";
  const input = value as Record<string, unknown>;
  const direct = firstString(input, [
    "text",
    "content",
    "delta",
    "chunk",
    "stdout",
    "partial",
    "output",
    "message",
    "command",
  ]);
  if (direct) return clean(direct, max);
  for (
    const key of [
      "content",
      "delta",
      "partial",
      "result",
      "data",
      "blocks",
      "parts",
      "output",
    ]
  ) {
    const nested = textOf(input[key], max);
    if (nested !== "") return nested;
  }
  return "";
}

function pidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // ESRCH means gone; EPERM means alive but owned by somebody else.
    return (error as NodeJS.ErrnoException)?.code === "EPERM";
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function liveSessions(
  sessions: SessionRecord[],
  at = Date.now(),
): SessionRecord[] {
  return sessions.filter((s) =>
    pidAlive(Number(s.pid) || -1) &&
    at - Number(s.updatedAt || 0) < STALE_SESSION_MS
  );
}

function readRegistry(): Registry {
  try {
    const parsed = JSON.parse(readFileSync(REGISTRY_FILE, "utf8")) as Partial<
      Registry
    >;
    return {
      v: 2,
      updated: Number(parsed.updated) || 0,
      sessions: Array.isArray(parsed.sessions)
        ? (parsed.sessions as SessionRecord[])
        : [],
    };
  } catch {
    return { v: 2, updated: 0, sessions: [] };
  }
}

function writeRegistry(registry: Registry): void {
  mkdirSync(CACHE_DIR, { recursive: true });
  writeFileSync(REGISTRY_FILE, JSON.stringify(registry));
}

/** Read, edit, write, with writers serialised against each other. */
async function withLock(edit: (registry: Registry) => void): Promise<boolean> {
  mkdirSync(CACHE_DIR, { recursive: true });
  const deadline = Date.now() + LOCK_WAIT_MS;
  let acquired = false;
  for (let attempt = 0; !acquired; attempt += 1) {
    try {
      mkdirSync(LOCK_DIR);
      acquired = true;
    } catch (error) {
      if ((error as NodeJS.ErrnoException)?.code !== "EEXIST") return false;
      let age = 0;
      try {
        age = Date.now() - statSync(LOCK_DIR).mtimeMs;
      } catch {
        age = 0;
      }
      // A writer killed between mkdir and rmdir leaves the lock behind; once
      // it is clearly stale, take it over rather than stop publishing.
      if (age > LOCK_STALE_MS) {
        try {
          rmdirSync(LOCK_DIR);
        } catch {
          /* lost the race; keep waiting */
        }
      }
      if (Date.now() > deadline) return false;
      await sleep(Math.min(200, 20 * (attempt + 1)));
    }
  }
  try {
    const registry = readRegistry();
    edit(registry);
    writeRegistry(registry);
    return true;
  } finally {
    try {
      rmdirSync(LOCK_DIR);
    } catch {
      /* already released elsewhere */
    }
  }
}

function sanitizeId(value: string): string {
  return value.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 64) ||
    `pi-${process.pid}`;
}

export default function (pi: ExtensionAPI) {
  exec = pi.exec.bind(pi);

  const inHyprland = !!process.env.HYPRLAND_INSTANCE_SIGNATURE;
  const id = sanitizeId(`pid${process.pid}`);

  let record: SessionRecord | null = null;
  let heartbeat: ReturnType<typeof setInterval> | null = null;
  let coalesce: ReturnType<typeof setTimeout> | null = null;
  let lastWrite = 0;
  let queue: Promise<void> = Promise.resolve();
  let settled = true;
  let toolsThisRun = 0;
  let lastSummary = "";

  function flush(): void {
    if (coalesce) {
      clearTimeout(coalesce);
      coalesce = null;
    }
    if (!record) return;
    const snapshot: SessionRecord = { ...record, bubbles: [...record.bubbles] };
    lastWrite = Date.now();
    queue = queue.then(async () => {
      await withLock((registry) => {
        registry.updated = Date.now();
        registry.sessions = [
          ...liveSessions(registry.sessions).filter((s) =>
            s.id !== snapshot.id
          ),
          snapshot,
        ].sort(
          (a, b) =>
            rank(a) - rank(b) ||
            Number(b.updatedAt || 0) - Number(a.updatedAt || 0),
        );
      });
    });
  }

  /** Attention first, then finished, then working; newest first inside each. */
  function rank(s: SessionRecord): number {
    if (s.needsAttention) return 0;
    if (s.state === "done") return 1;
    return s.state === "idle" ? 3 : 2;
  }

  /** Publish this session's state. Cheap enough to call on every event. */
  function publish(
    state: PresenceState,
    patch: {
      tool?: string;
      detail?: string;
      bubble?: string;
      needsAttention?: boolean;
      turn?: number;
    } = {},
    opts: { force?: boolean } = {},
  ): void {
    if (!record) return;
    const ts = Date.now();
    const quiet = state === "idle" || state === "thinking" ||
      state === "done" || state === "off";
    record = {
      ...record,
      state,
      tool: patch.tool ?? (quiet ? "" : record.tool),
      detail: patch.detail ?? (quiet ? "" : record.detail),
      needsAttention: patch.needsAttention ??
        (state === "waiting" || state === "asking"),
      turn: patch.turn ?? record.turn,
      updatedAt: ts,
    };
    const text = clean(patch.bubble ?? STATE_LABELS[state], 80);
    const tail = record.bubbles.at(-1);
    if (text !== "" && (tail?.text !== text || tail?.state !== state)) {
      record.bubbles = [...record.bubbles, { ts, state, text }].slice(
        -BUBBLE_CAP,
      );
    }
    if (!opts.force && ts - lastWrite < MIN_WRITE_MS) {
      // Deferred, not dropped: the coalesced write carries the whole record.
      if (!coalesce) coalesce = setTimeout(flush, MIN_WRITE_MS);
      return;
    }
    flush();
  }

  function forget(): void {
    if (coalesce) clearTimeout(coalesce);
    coalesce = null;
    queue = queue.then(async () => {
      await withLock((registry) => {
        registry.updated = Date.now();
        registry.sessions = liveSessions(registry.sessions).filter((s) =>
          s.id !== id
        );
      });
    });
  }

  function setTitles(label: string, ctx: ExtensionContext): void {
    const text = cleanTitle(label);
    try {
      if (process.env.TMUX) {
        void exec("tmux", ["rename-window", text], { timeout: 2000 });
      }
      ctx.ui.setTitle(text);
    } catch {
      /* the title is best-effort */
    }
  }

  async function focusSelf(): Promise<void> {
    if (!inHyprland || !record?.address) return;
    // The terminal loses focus to a popup, a notification or another window
    // while Pi runs; bringing it back is how the border stays honest.
    await exec("hyprctl", [
      "dispatch",
      `hl.dsp.focus({ window = "address:${record.address}" })`,
    ], { timeout: 3000 }).catch(
      () => undefined,
    );
  }

  /** The focused window is the terminal hosting Pi; capture it so the popup
   * and the finish notification can find their way back to it. */
  async function captureWindow(): Promise<void> {
    if (!inHyprland) return;
    try {
      const r = await exec("hyprctl", ["activewindow", "-j"], {
        timeout: 4000,
      });
      if (r.code !== 0) return;
      const w = JSON.parse(r.stdout) as { address?: string; class?: string };
      if (!record || !w.address) return;
      record = {
        ...record,
        address: String(w.address),
        klass: cleanTitle(w.class || record.klass || "foot"),
      };
    } catch {
      /* no window to jump to; the popup falls back to focusing by class */
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    settled = false;
    toolsThisRun = 0;
    lastSummary = "";
    const name = clean(ctx.sessionManager.getSessionName() ?? "", 60);
    const cwd = ctx.cwd || ctx.sessionManager.getCwd() || homedir();
    const project = cleanTitle(
      basename(String(cwd).replace(/\/+$/, "")) || "pi",
    );
    record = {
      id,
      pid: process.pid,
      host: cleanTitle(hostname()),
      cwd,
      project,
      name,
      state: "idle",
      tool: "",
      detail: "",
      model: clean(ctx.model?.id ?? ctx.model?.name ?? "", 40),
      address: record?.address ?? "",
      klass: record?.klass ?? "foot",
      needsAttention: false,
      turn: 0,
      tools: 0,
      startedAt: Date.now(),
      updatedAt: Date.now(),
      bubbles: [],
    };
    await captureWindow();
    publish("idle", {
      bubble: name ? `session “${name}”` : `session in ${project}`,
    }, { force: true });
    setTitles(`${GLYPH} pi — ${project}`, ctx);
    if (heartbeat) clearInterval(heartbeat);
    heartbeat = setInterval(() => {
      if (!record) return;
      record = { ...record, updatedAt: Date.now() };
      flush();
    }, HEARTBEAT_MS);
  });

  pi.on("session_info_changed", (_event, ctx) => {
    if (!record) return;
    record = {
      ...record,
      name: clean(ctx.sessionManager.getSessionName() ?? "", 60),
    };
    publish(record.state, { bubble: `named “${record.name || "unnamed"}”` }, {
      force: true,
    });
  });

  pi.on("model_select", (event) => {
    if (!record) return;
    const model = (event as { model?: { id?: string; name?: string } })?.model;
    record = {
      ...record,
      model: clean(model?.id ?? model?.name ?? record.model, 40),
    };
  });

  pi.on("before_agent_start", async (event, ctx) => {
    settled = false;
    toolsThisRun = 0;
    if (!record) return;
    const turn = Number(record.turn) + 1;
    const prompt = clean((event as { prompt?: string })?.prompt ?? "", 70);
    publish("thinking", {
      bubble: prompt ? `prompt · ${prompt}` : "thinking",
      turn,
    }, { force: true });
    setTitles(`${GLYPH} pi — working`, ctx);
    await focusSelf();
  });

  pi.on("turn_start", (event) => {
    if (!record) return;
    const turn = Number(
      (event as { turnIndex?: number })?.turnIndex ?? record.turn - 1,
    );
    publish("thinking", { bubble: `turn ${turn + 1}`, turn: turn + 1 });
  });

  pi.on("tool_call", (event) => {
    if (!record) return;
    // A question asked of the user is the one thing worth interrupting for.
    if (stateForTool(String(event.toolName ?? "")) === "asking") {
      publish("asking", { tool: String(event.toolName) });
    }
  });

  pi.on("tool_execution_start", (event) => {
    if (!record) return;
    toolsThisRun += 1;
    record = { ...record, tools: Number(record.tools) + 1 };
    const state = stateForTool(String(event.toolName ?? ""));
    const subject = toolSubject(String(event.toolName ?? ""), event.args);
    publish(state, {
      tool: String(event.toolName ?? ""),
      detail: subject,
      bubble: subject
        ? `${STATE_LABELS[state]} · ${subject}`
        : STATE_LABELS[state],
    });
  });

  pi.on("tool_execution_update", (event) => {
    if (!record) return;
    const partial = (event as { partialResult?: unknown }).partialResult;
    // Live tool output scrolls, so the tail is shown: the start of a long run
    // is stale the moment it goes past.
    const text = tail(textOf(partial, 4000), 80);
    if (text === "") return;
    publish(stateForTool(String(event.toolName ?? "")), { detail: text });
  });

  pi.on("tool_execution_end", (event) => {
    if (!record) return;
    const failed = Boolean((event as { isError?: boolean }).isError);
    const ms = Number((event as { durationMs?: number }).durationMs ?? 0);
    const took = ms >= 1000
      ? `${(ms / 1000).toFixed(1)}s`
      : `${Math.round(ms)}ms`;
    const name = clean(String(event.toolName ?? "tool"), 30);
    publish(settled ? "done" : "thinking", {
      bubble: `${failed ? "✗" : "✓"} ${name}${ms ? ` · ${took}` : ""}`,
    });
    if (failed) publish("error", { bubble: `error · ${name}`, detail: "" });
  });

  pi.on("turn_end", (event) => {
    const summary = textOf((event as { message?: unknown }).message);
    if (summary !== "") lastSummary = summary;
  });

  pi.on("agent_start", () => {
    publish("thinking", { bubble: "thinking" });
  });

  pi.on("agent_end", () => {
    publish(settled ? "done" : "thinking", {
      bubble: `finished ${toolsThisRun} tools`,
    });
  });

  pi.on("ui_prompt_start", (event) => {
    if (!record) return;
    const title = clean((event as { title?: string })?.title ?? "", 60);
    publish("waiting", {
      tool: clean((event as { kind?: string })?.kind ?? "", 20),
      detail: title,
      bubble: title ? `waiting for you · ${title}` : "waiting for you",
      needsAttention: true,
    });
  });

  pi.on("ui_prompt_end", () => {
    publish(settled ? "done" : "thinking", {
      bubble: "answer received",
      needsAttention: false,
    });
  });

  pi.on("user_bash", (event) => {
    if (!record) return;
    const command = clean((event as { command?: string })?.command ?? "", 80);
    publish("bash", {
      tool: "bash",
      detail: command,
      bubble: `executing bash · ${command}`,
    }, { force: true });
    // Returning undefined: pi runs the command locally, unchanged.
  });

  pi.on("input", (event) => {
    if (!record) return undefined;
    const text = clean((event as { text?: string })?.text ?? "", 60);
    if (text === "" || text.startsWith("/")) return undefined;
    const streaming = (event as { streamingBehavior?: string })
      ?.streamingBehavior;
    publish(streaming ? "thinking" : record.state, {
      bubble: streaming ? `queued · ${text}` : `you · ${text}`,
      needsAttention: false,
    });
    return undefined;
  });

  pi.on("session_before_compact", () => {
    publish("compacting", {}, { force: true });
  });

  pi.on("agent_settled", async (event, ctx) => {
    if (!record) return;
    const aborted = Boolean((event as { aborted?: boolean })?.aborted);
    settled = true;
    publish(aborted ? "idle" : "done", {
      bubble: aborted ? "stopped" : lastSummary || "ready",
      needsAttention: false,
    });
    setTitles(`${GLYPH} pi — ${record.project}`, ctx);
    if (aborted) return;
    // The Jump button's argv is run verbatim by the notification daemon
    // (bash exec "$@"), so it must be a dispatcher that really focuses:
    // hl.dsp.focus({ window = "address:…" }). hl.dsp.window.bring_to_top
    // only re-stacks a window inside its own workspace and never moves
    // focus, which is why the old button looked dead.
    const jump = record.address
      ? [
        "hyprctl",
        "dispatch",
        `hl.dsp.focus({ window = "address:${record.address}" })`,
      ]
      : ["omarchy-hyprland-focus-app", record.klass];
    await exec(
      "omarchy",
      [
        "notification",
        "send",
        `${GLYPH} Pi ready`,
        lastSummary || `Finished ${toolsThisRun} tools in ${record.project}.`,
        "-g",
        GLYPH,
        "-u",
        "normal",
        "-t",
        "12000",
        "--action",
        "Jump to Pi",
        ...jump,
      ],
      { timeout: 5000 },
    ).catch(() => undefined);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    if (heartbeat) {
      clearInterval(heartbeat);
      heartbeat = null;
    }
    record = null;
    forget();
    // The last Pi on this terminal is gone: hand the title back.
    setTitles(
      cleanTitle(basename(String(ctx.cwd ?? homedir()).replace(/\/+$/, ""))) ||
        "terminal",
      ctx,
    );
    await queue;
  });

  pi.registerCommand("presence", {
    description: "Pi presence: report sessions and open the bar popup",
    handler: async (_args, ctx) => {
      const sessions = liveSessions(readRegistry().sessions);
      ctx.ui.notify(
        `${GLYPH} ${sessions.length} Pi ${
          sessions.length === 1 ? "session" : "sessions"
        } · this one is ${
          record?.state ?? "idle"
        } · the π in the bar opens the list`,
        "info",
      );
      // The bar owns popup mapping, and `shell toggle <module>` is the route it
      // exposes for panels. It is also the only one that works from here: a
      // popup opened by IPC has no pointer serial, and the bar will not map a
      // grab it cannot arbitrate.
      await exec("omarchy-shell", ["shell", "toggle", PRESENCE_MODULE_ID], {
        timeout: 3000,
      }).catch(() => undefined);
    },
  });
}
