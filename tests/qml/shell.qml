import Quickshell
import QtQuick
import qs.Commons as Commons
import "Model.js" as Model

// Offscreen harness for pi.presence: the real Model.js against the real status
// shape, plus the real bar widget loaded so its bindings run.
//
// Run by tests/model_contract.py, which reads the tally and kills the process
// (Quickshell wires no Qt.exit here). Prints exactly:
//   qml: ok <name> / qml: FAIL <name> / qml: ALL OK
ShellRoot {
  Item {
    id: harness

    property int failures: 0

    function check(name, ok) {
      if (!ok) failures++;
      console.log((ok ? "qml: ok " : "qml: FAIL ") + name);
    }

    // The widget, with the bar host absent by design: the plugin must still
    // resolve its colours and lay out, which is what a theme swap tests.
    BarPanel {
      id: barPanel
    }

    // The popup, with no bar and no anchor: the same file the bar widget loads
    // through its Loader, exercised directly so its rows and bindings run.
    PresencePanel {
      id: popupPanel
    }

    // A registry with three sessions in three states: working, waiting on the
    // user, idle. Timestamps are relative to now, because freshness is part of
    // the contract: a session 60s old must drop out.
    property real base: Date.now()
    property string sample: JSON.stringify({
      v: 2,
      updated: harness.base - 200,
      sessions: [
        { id: "100", pid: 100, host: "zen", cwd: "/home/u/Work/Dotfiles", project: "Dotfiles",
          name: "Dotfiles", state: "bash", tool: "bash",
          detail: "executing bash · omarchy plugin validate", model: "qwen3.8",
          address: "0x55e5a204f4e0", klass: "foot", needsAttention: false,
          turn: 3, tools: 12, startedAt: harness.base - 50000, updatedAt: harness.base - 1000,
          bubbles: [{ ts: harness.base - 50000, state: "thinking", text: "thinking" },
                    { ts: harness.base - 20000, state: "editing", text: "editing · Panel.qml" },
                    { ts: harness.base - 1000, state: "bash", text: "executing bash · omarchy plugin validate" }] },
        { id: "200", pid: 200, host: "zen", cwd: "/home/u/Work/Notes", project: "Notes",
          name: "Notes", state: "asking", tool: "ask", detail: "asking a question",
          model: "qwen3.8", address: "", klass: "foot", needsAttention: true,
          turn: 1, tools: 0, startedAt: harness.base - 120000, updatedAt: harness.base - 2000,
          bubbles: [{ ts: harness.base - 2000, state: "asking", text: "asking a question" }] },
        { id: "300", pid: 300, host: "zen", cwd: "/home/u", project: "~",
          name: "~", state: "idle", tool: "", detail: "pi idle", model: "qwen3.8",
          address: "0xaaa", klass: "foot", needsAttention: false,
          turn: 9, tools: 40, startedAt: harness.base - 600000, updatedAt: harness.base - 4000, bubbles: [] }
      ]
    })

    Component.onCompleted: {
      var now = harness.base;
      var frame = Model.parse(harness.sample, now);

      console.log("registry");
      check("parse accepts the registry", frame.ok === true);
      check("counts every session", frame.count === 3);
      check("counts working sessions", frame.live === 1);
      check("counts sessions needing attention", frame.attention === 1);
      check("attention sorts first", frame.sessions[0].id === "200");
      check("working sorts before idle", frame.sessions[1].id === "100" && frame.sessions[2].id === "300");

      console.log("reads that must not pass as empty");
      // A torn read is normal: the extension writes the registry in place and the
      // watcher fires mid-write, so parse has to report failure and the widget
      // keeps the frame it already has.
      check("torn read reports failure", Model.parse(harness.sample.substring(0, 120), now).ok === false);
      check("malformed json reports failure", Model.parse("{not json", now).ok === false);
      // No file is not a failed read: it means no Pi is running, and the bar has
      // to clear rather than keep a session that ended hours ago.
      check("missing file clears the list",
        Model.parse("", now).ok === true && Model.parse("", now).count === 0);
      check("wrong version is ignored", Model.parse(JSON.stringify({ v: 1, sessions: [] }), now).ok === false);

      console.log("staleness");
      // A session whose process died mid-work must stay out of the list.
      var stale = JSON.parse(harness.sample);
      stale.sessions[0].updatedAt = now - 60000;
      var staleFrame = Model.parse(JSON.stringify(stale), now);
      check("stale session drops out", staleFrame.count === 2);
      var ids = [];
      for (var k = 0; k < staleFrame.sessions.length; k++) ids.push(staleFrame.sessions[k].id);
      check("live sessions stay listed",
        ids.indexOf("100") === -1 && ids.indexOf("200") !== -1 && ids.indexOf("300") !== -1);

      console.log("untrusted text");
      // Everything shown comes from tool output and terminal titles.
      var markup = "<img src=\"https://example.invalid/x.png\">";
      check("markup survives as literal text", Model.cap(markup, 120) === markup);
      check("long detail is capped", Model.cap(new Array(401).join("x"), 160).length === 160);
      check("control characters are stripped", Model.cap("a\nb\tc", 40) === "a b c");
      check("name falls back to project", Model.nameOf({ name: "", project: "Dotfiles" }) === "Dotfiles");
      check("name falls back to cwd leaf", Model.nameOf({ name: "", project: "", cwd: "/home/u/Work/Notes" }) === "Notes");

      console.log("bubbles");
      var working = frame.sessions[1];
      var thread = Model.threadOf(working, 3);
      check("thread is capped", thread.length === 3);
      check("thread is oldest first", thread[0].state === "thinking" && thread[2].state === "bash");
      check("session without bubbles yields none", Model.threadOf(frame.sessions[2], 3).length === 0);

      console.log("glyphs and labels");
      check("state label is readable", Model.label("bash") === "executing bash");
      check("unknown state falls back to its own name", Model.label("nonsense") === "nonsense");
      check("bar glyph changes when working", Model.barGlyph(false, false) !== Model.barGlyph(true, false));
      check("bar glyph changes for attention", Model.barGlyph(true, false) !== Model.barGlyph(true, true));
      var states = ["off", "idle", "thinking", "tool", "bash", "editing", "reading", "searching",
        "browsing", "delegating", "planning", "asking", "waiting", "compacting", "done", "error"];
      var covered = true;
      for (var i = 0; i < states.length; i++) {
        if (Model.glyph(states[i]).length === 0) covered = false;
        if (Model.LABELS[states[i]] === undefined) covered = false;
        if (Model.TONES[states[i]] === undefined) covered = false;
      }
      check("every state has a glyph, a label and a tone", covered);

      console.log("times");
      check("age formatting", Model.ago(now - 5000, now) === "5s" && Model.ago(now - 125000, now) === "2m");
      check("elapsed duration", Model.duration(now - 65000, now, now) === "1m 5s");

      console.log("jump");
      check("jump focuses by window address",
        Model.jumpCommand({ address: "0x55e5a204f4e0", klass: "foot" })[2]
        === "hl.dsp.focus({ window = \"address:0x55e5a204f4e0\" })");
      check("no address falls back to the app id",
        Model.jumpCommand({ address: "", klass: "foot" })[0] === "omarchy-hyprland-focus-app");
      check("address is sanitised",
        Model.jumpCommand({ address: "0x55e5; rm -rf /", klass: "foot" })[2]
        === "hl.dsp.focus({ window = \"address:0x55e5\" })");

      console.log("bar widget");
      // Feeding the frame directly is the same path the file watcher uses.
      barPanel.apply(harness.sample);
      check("widget shows every session", barPanel.count === 3);
      check("widget counts working sessions", barPanel.live === 1);
      check("widget flags attention", barPanel.attention === 1);
      check("widget colours the icon for attention",
        String(barPanel.barColor) === String(Commons.Color.urgent));
      check("widget names the leading session", barPanel.primary === "asking");
      check("tooltip counts the sessions", barPanel.barTooltip.indexOf("3") === 0);
      check("widget forwards open to its panel", barPanel.opened === popupPanel.opened);
      // A torn read must keep the last good frame rather than blank the bar.
      barPanel.apply(harness.sample.substring(0, 120));
      check("torn read keeps the last frame", barPanel.count === 3);
      barPanel.apply("");
      check("missing file empties the list", barPanel.count === 0);
      check("empty bar is the dimmed foreground",
        String(barPanel.barColor) === String(Qt.darker(barPanel.barForeground, 1.9)));

      console.log("popup panel");
      popupPanel.apply(harness.sample);
      check("panel lists every session", popupPanel.count === 3);
      check("panel keeps live rows", popupPanel.live === 1);
      popupPanel.cursor = 99;
      popupPanel.apply(harness.sample);
      check("cursor cannot run past the rows", popupPanel.cursor === 2);
      check("row lookup", popupPanel.sessionAt(0).id === "200");
      check("row lookup past the end is null", popupPanel.sessionAt(9) === null);
      popupPanel.jump(null);
      check("jump on an empty selection is inert", popupPanel.cursor === 2);
      popupPanel.jump(popupPanel.sessionAt(0));
      check("jump closes the panel", popupPanel.opened === false);
      check("panel icon is the robot", Model.barGlyph(false, false) === "\udb81\ude05");

      console.log(failures === 0 ? "qml: ALL OK" : "qml: " + failures + " FAILED");
    }
  }
}
