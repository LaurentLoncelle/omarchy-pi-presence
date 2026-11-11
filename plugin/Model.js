// Pure view helpers for the pi.presence panel. No QML, no singletons, so
// tests can import this file directly.
//
// Everything the panel displays about a session comes out of a file written by
// another process, so it is untrusted: `cap` is the only text path to the
// screen and it strips control characters, collapses whitespace and caps the
// length. Every Text in the panel is Text.PlainText, so markup-shaped input
// renders as the literal text it is.
.pragma library

// Material Design Icons codepoints, each checked against the icon set's own
// metadata and against the bar font's cmap by tests/model_contract.py. These are
// astral codepoints: a \u escape in QML cannot reach them, so compare with
// codePointAt, and never guess one from the list's order. No comment goes inside
// this table: the suite reads it with a key:value scan, and a colon in a comment
// reads as a key.
var GLYPHS = {
  bar: 0xf03ff,          // pi
  barLive: 0xf0400,     // pi-box
  thinking: 0xf09d1,     // brain
  tool: 0xf05b7,         // wrench
  bash: 0xf07b7,         // console-line
  editing: 0xf03eb,      // pencil
  reading: 0xf0208,      // eye
  searching: 0xf0349,    // magnify
  browsing: 0xf03cc,     // open-in-new
  delegating: 0xf167a,   // robot-outline
  planning: 0xf10d4,     // clipboard-list
  asking: 0xf02d7,       // help-circle
  waiting: 0xf05ce,      // clock-alert-outline
  compacting: 0xf0996,   // progress-clock
  done: 0xf05e0,         // check-circle
  idle: 0xf0766,         // circle-outline
  error: 0xf0028,        // alert-circle
  jump: 0xf03cc,         // open-in-new
  refresh: 0xf0450,      // refresh
  close: 0xf0156         // close
};

var LABELS = {
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
  error: "error"
};

// Which palette the row's glyph and bubble take: attention is urgent, work is
// accent, a settled session is quiet.
var TONES = {
  off: "dim",
  idle: "dim",
  done: "muted",
  error: "urgent",
  waiting: "urgent",
  asking: "urgent",
  thinking: "accent",
  tool: "accent",
  bash: "accent",
  editing: "accent",
  reading: "accent",
  searching: "accent",
  browsing: "accent",
  delegating: "accent",
  planning: "accent",
  compacting: "accent"
};

// Live means the model is doing something right now. A session that is asking,
// waiting, done or in error is not live: it is stopped, and it is attention
// that lights those, so the bar pulse keeps exactly one meaning.
var LIVE_STATES = ["thinking", "tool", "bash", "editing", "reading", "searching", "browsing",
  "delegating", "planning", "compacting"];

function cap(value, max) {
  var text = String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  var limit = max || 90;
  return text.length > limit ? text.substring(0, Math.max(1, limit - 1)) + "…" : text;
}

function glyph(state) {
  var code = GLYPHS[state] !== undefined ? GLYPHS[state] : GLYPHS.tool;
  return String.fromCodePoint(code);
}

// The pi, boxed while a session works. Attention is colour, not shape: MDI has
// no pi-circle, and a third shape borrowed from another icon is exactly the bug
// this file had once.
function barGlyph(live, attention) {
  return String.fromCodePoint(live ? GLYPHS.barLive : GLYPHS.bar);
}

function label(state) {
  return LABELS[state] !== undefined ? LABELS[state] : cap(state, 24);
}

function tone(state) {
  return TONES[state] !== undefined ? TONES[state] : "accent";
}

function isLive(state) {
  return LIVE_STATES.indexOf(state) !== -1;
}

function ago(ts, nowMs) {
  var then = Number(ts) || 0;
  if (then <= 0) return "";
  var secs = Math.max(0, Math.floor(((Number(nowMs) || Date.now()) - then) / 1000));
  if (secs < 60) return secs + "s";
  if (secs < 3600) return Math.floor(secs / 60) + "m";
  if (secs < 86400) return Math.floor(secs / 3600) + "h";
  return Math.floor(secs / 86400) + "d";
}

function duration(startedAt, updatedAt, nowMs) {
  var a = Number(startedAt) || 0;
  var b = Math.max(Number(startedAt) || 0, Number(updatedAt) || 0);
  var span = Math.max(0, Math.floor(((Number(nowMs) || Date.now()) - a) / 1000));
  if (b <= a) return "";
  if (span < 60) return span + "s";
  if (span < 3600) return Math.floor(span / 60) + "m " + (span % 60) + "s";
  return Math.floor(span / 3600) + "h " + Math.floor((span % 3600) / 60) + "m";
}

// Attention first, then work in flight, then settled, then idle. Newest leads
// inside each group, so the session that just moved sits at the top.
function rank(session) {
  if (session && session.needsAttention) return 0;
  if (session && isLive(session.state)) return 1;
  if (session && session.state === "done") return 2;
  return 3;
}

function nameOf(session) {
  if (!session) return "";
  var name = cap(session.name, 40);
  if (name !== "") return name;
  var project = cap(session.project, 40);
  if (project !== "") return project;
  // The cwd's leaf is what the user typed to get here, and a session with no
  // name and no project is still a session in a directory they know.
  var cwd = cap(session.cwd, 120).replace(/\/+$/, "");
  if (cwd === "" || cwd === "/") return cwd === "/" ? "/" : "pi";
  return cwd.substring(cwd.lastIndexOf("/") + 1);
}

// The bubble's line: the latest thing that happened, never the raw tool dump.
function bubbleOf(session) {
  if (!session) return "";
  var bubbles = Array.isArray(session.bubbles) ? session.bubbles : [];
  for (var i = bubbles.length - 1; i >= 0; i--) {
    var text = cap(bubbles[i] && bubbles[i].text, 120);
    if (text !== "") return text;
  }
  return label(session.state);
}

// The last few bubbles, oldest first, so a session reads as a short thread.
function threadOf(session, limit) {
  var bubbles = Array.isArray(session && session.bubbles) ? session.bubbles : [];
  var keep = limit || 3;
  var out = [];
  for (var i = Math.max(0, bubbles.length - keep); i < bubbles.length; i++) {
    var b = bubbles[i];
    if (!b) continue;
    var text = cap(b.text, 120);
    if (text === "") continue;
    out.push({ ts: Number(b.ts) || 0, state: String(b.state || "tool"), text: text });
  }
  return out;
}

function metaOf(session, nowMs) {
  var bits = [];
  var model = cap(session && session.model, 28);
  if (model !== "") bits.push(model);
  var tools = Number(session && session.tools) || 0;
  if (tools > 0) bits.push(tools + (tools === 1 ? " tool" : " tools"));
  var span = duration(session && session.startedAt, session && session.updatedAt, nowMs);
  if (span !== "") bits.push(span);
  return bits.join(" · ");
}

// A session's window is only focusable while its process is alive; the panel
// cannot probe pids, so the extension's heartbeat is the liveness signal.
function isFresh(session, nowMs, ttl) {
  var life = ttl || 20000;
  return (Number(session && session.updatedAt) || 0) > 0 &&
    (Number(nowMs) || Date.now()) - (Number(session && session.updatedAt) || 0) < life;
}

function sanitizeId(value) {
  return String(value || "").replace(/[^A-Za-z0-9._-]/g, "").slice(0, 64);
}

// The argv that focuses a session's terminal. Hyprland runs the notification
// action and the panel's jump button through the same path, so the shape is
// built here and tested here rather than assembled at each call site:
// hl.dsp.focus({ window = "address:…" }) really moves focus, while
// hl.dsp.window.bring_to_top only re-stacks inside the workspace and looks
// dead. A session with no captured address falls back to the app id.
function jumpCommand(session) {
  // Only a leading 0x… is an address; anything the tail smuggles in is gone.
  var match = /^0x[0-9a-fA-F]+/.exec(cap(session && session.address, 32));
  var address = match ? match[0] : "";
  if (address !== "") {
    return ["hyprctl", "dispatch", "hl.dsp.focus({ window = \"address:" + address + "\" })"];
  }
  var klass = cap(session && session.klass, 32).replace(/["'`$\\]/g, "");
  return ["omarchy-hyprland-focus-app", klass !== "" ? klass : "foot"];
}

function parse(raw, nowMs) {
  var at = Number(nowMs) || Date.now();
  // ok:false means the frame could not be read, so the caller keeps the frame
  // it already has. An empty file is not that: no file means no Pi is running,
  // and the bar has to clear rather than keep a session that ended hours ago.
  var bad = { ok: false, at: at, sessions: [], count: 0, live: 0, attention: 0 };
  var text = String(raw === undefined || raw === null ? "" : raw).trim();
  if (text === "") return { ok: true, at: at, sessions: [], count: 0, live: 0, attention: 0 };
  var data;
  try {
    data = JSON.parse(text);
  } catch (error) {
    // A torn read: the extension writes in place and the watcher fires mid-write.
    return bad;
  }
  // The version is the contract with the extension. A frame in a format this
  // widget does not understand is not an empty registry.
  if (!data || typeof data !== "object" || Number(data.v) !== 2) return bad;
  var list = Array.isArray(data.sessions) ? data.sessions : [];
  var sessions = [];
  for (var i = 0; i < list.length; i++) {
    var s = list[i];
    if (!s || typeof s !== "object") continue;
    if (!isFresh(s, at)) continue;
    sessions.push({
      id: cap(s.id, 64),
      pid: Number(s.pid) || 0,
      host: cap(s.host, 32),
      cwd: cap(s.cwd, 120),
      project: cap(s.project, 40) || "pi",
      name: cap(s.name, 40),
      state: String(LABELS[s.state] ? s.state : "tool"),
      tool: cap(s.tool, 24),
      detail: cap(s.detail, 120),
      model: cap(s.model, 28),
      address: cap(s.address, 32),
      klass: cap(s.klass, 32),
      needsAttention: s.needsAttention === true,
      turn: Number(s.turn) || 0,
      tools: Number(s.tools) || 0,
      startedAt: Number(s.startedAt) || 0,
      updatedAt: Number(s.updatedAt) || 0,
      bubbles: threadOf(s, 6)
    });
  }
  sessions.sort(function (a, b) {
    return rank(a) - rank(b) || b.updatedAt - a.updatedAt;
  });
  var live = 0;
  var attention = 0;
  for (var j = 0; j < sessions.length; j++) {
    if (isLive(sessions[j].state)) live += 1;
    if (sessions[j].needsAttention) attention += 1;
  }
  return { ok: true, at: at, sessions: sessions, count: sessions.length, live: live, attention: attention };
}
