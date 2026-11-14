import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Pi presence service: the frame around the terminal, driven by the same file
// the bar widget reads.
//
// The frame is the window's real Hyprland border, not a painted overlay. While
// any Pi session works this pushes a wider accent gradient onto
// general:col.active_border and loops the compositor's borderangle animation;
// when every session settles it restores the baseline captured at startup. A
// session waiting on you gets a solid urgent border, so the frame answers the
// two questions the bar cannot from across the room: is it busy, and does it
// want me.
//
// Hyprland draws the border, so it follows window moves, resizes, rounding,
// fullscreen state and occlusion for free. An overlay would have to poll
// geometry, paint above the bar and stay mapped all the time.
//
// Two Hyprland specifics matter:
//
//   * Omarchy's config uses the Lua parser, so `hyprctl keyword` is rejected
//     outright ("keyword can't work with non-legacy parsers") and per-window
//     `setprop` no longer exists. `hyprctl eval` is the only runtime
//     interface, and it is global, so the frame applies to the active window
//     the way a border normally does.
//   * Colours are passed as rgba(RRGGBBAA) and reported back as AARRGGBB.
//     Feeding the reported form straight back in shifts every byte by two and
//     repaints the border a different colour.
//
// The baseline is mirrored to disk because a shell killed mid-work restores
// nothing: without the mirror the next startup would capture the boosted border
// as its own baseline and the theme would stay broken.
Item {
  id: service

  // Edge triggered, so a stream of status writes does not re-issue hyprctl.
  // "off" restores the theme, "working" the accent gradient, "attention" a
  // solid urgent frame.
  property string frame: "off"
  property bool baselineReady: false
  property bool evalBusy: false

  // Baseline: what the compositor had before this plugin touched anything.
  property string baseSize: "1"
  property string baseBorder: ""
  property bool baseAngleEnabled: false
  property string baseAngleBezier: "default"
  property string baseAngleSpeed: "1"

  property var evalQueue: []

  readonly property color accent: Commons.Color.accent
  readonly property color accentBright: Qt.lighter(Commons.Color.accent, 1.45)
  readonly property color alert: Commons.Color.urgent
  // The border is real geometry taken from the window, so it stays thin:
  // three pixels read as a glow at 4K without eating content.
  readonly property int workingSize: 3
  readonly property int attentionSize: 4

  readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/pi-presence"
  readonly property string registryPath: cacheDir + "/sessions.json"
  readonly property string baselinePath: cacheDir + "/border-baseline.json"

  function hex2(n) {
    var s = Math.max(0, Math.min(255, Math.round(n))).toString(16);
    return s.length < 2 ? "0" + s : s;
  }

  function rgba(c, a) {
    return "rgba(" + hex2(c.r * 255) + hex2(c.g * 255) + hex2(c.b * 255) + hex2(a * 255) + ")";
  }

  // AARRGGBB (as reported) -> rgba(RRGGBBAA) (as consumed).
  function argbToRgba(token) {
    return "rgba(" + token.substring(2, 8) + token.substring(0, 2) + ")";
  }

  // Single colours stay single colours, so the theme's flat accent is restored
  // as authored. The value must come back quoted: unquoted, Lua reads
  // rgba(89b4faff) as a call to an undefined rgba() function and the whole
  // config statement fails silently.
  function borderValue(colors, angle) {
    if (colors.length === 0) return '""';
    if (colors.length === 1) return '"' + argbToRgba(colors[0]) + '"';
    var out = "";
    for (var i = 0; i < colors.length; i++)
      out += (i ? "," : "") + '"' + argbToRgba(colors[i]) + '"';
    return "{colors={" + out + "},angle=" + angle + "}";
  }

  function pumpEval() {
    if (service.evalBusy || service.evalQueue.length === 0) return;
    service.evalBusy = true;
    evalProcess.command = ["hyprctl", "eval", service.evalQueue.shift()];
    evalProcess.running = true;
  }

  // Serialised: a Process cannot be restarted while it is running, so issuing
  // the config eval and the animation eval back to back silently drops the
  // second one — the border shrank back while the gradient kept spinning.
  function evalConfig(lua) {
    service.evalQueue.push(lua);
    pumpEval();
  }

  // JSON contains only double quotes, so shell single quotes are safe here.
  // umask 077 and the chmods matter: this writes into the same private cache
  // directory as the session registry, and the default 022 umask would leave the
  // directory 0755 and the file 0644 for any local account to read on a home
  // that is traversable.
  function persistBaseline() {
    var json = JSON.stringify({
      border_size: baseSize,
      active_border: baseBorder,
      angle_enabled: baseAngleEnabled ? 1 : 0,
      angle_bezier: baseAngleBezier,
      angle_speed: baseAngleSpeed
    });
    persistProcess.command = ["bash", "-c",
      "umask 077 && mkdir -p '" + cacheDir + "' && " +
      "printf '%s' '" + json + "' > '" + baselinePath + "' && " +
      "chmod 700 '" + cacheDir + "' && chmod 600 '" + baselinePath + "'"];
    persistProcess.running = true;
  }

  function dropBaseline() {
    cleanupProcess.command = ["bash", "-c", "rm -f '" + baselinePath + "'"];
    cleanupProcess.running = true;
  }

  function applyWorking() {
    var grad = '{colors={"' + rgba(accent, 1.0) + '","' + rgba(accentBright, 1.0) + '"},angle=45}';
    evalConfig("hl.config({general={border_size=" + workingSize + ",col={active_border=" + grad + "}}})");
    evalConfig('hl.animation({leaf="borderangle",enabled=true,speed=18,bezier="linear",once=false})');
  }

  function applyAttention() {
    evalConfig("hl.config({general={border_size=" + attentionSize
      + ",col={active_border=\"" + rgba(alert, 1.0) + "\"}}})");
    evalConfig('hl.animation({leaf="borderangle",enabled=false})');
  }

  function restoreIdle() {
    var colors = baseBorder
      ? baseBorder.split(" ").filter(function (token) { return token.indexOf("deg") === -1; })
      : [];
    var border = colors.length ? borderValue(colors, 0) : '"' + rgba(accent, 1.0) + '"';
    evalConfig("hl.config({general={border_size=" + baseSize + ",col={active_border=" + border + "}}})");
    evalConfig('hl.animation({leaf="borderangle",enabled=' + (baseAngleEnabled ? "true" : "false")
      + ',speed=' + baseAngleSpeed + ',bezier="' + baseAngleBezier + '"})');
    dropBaseline();
  }

  // Edge triggered: the file is rewritten on every heartbeat, and a hyprctl
  // eval per beat would be pure churn.
  function setFrame(next) {
    if (next === service.frame) return;
    service.frame = next;
    if (!service.baselineReady) return;
    if (next === "working") service.applyWorking();
    else if (next === "attention") service.applyAttention();
    else service.restoreIdle();
  }

  function apply(raw) {
    var frame = Model.parse(raw, Date.now());
    if (!frame.ok) {
      service.setFrame("off");
      return;
    }
    if (frame.attention > 0) service.setFrame("attention");
    else if (frame.live > 0) service.setFrame("working");
    else service.setFrame("off");
  }

  Process {
    id: evalProcess
    onExited: function(code) {
      if (code !== 0)
        console.warn("pi-presence: hyprctl eval failed (exit " + code + ")",
          command ? command[command.length - 1] : "");
      service.evalBusy = false;
      service.pumpEval();
    }
  }

  Process {
    id: persistProcess
    onExited: function(code) {
      if (code !== 0) console.warn("pi-presence: baseline persist failed", code);
    }
  }

  Process {
    id: cleanupProcess
    onExited: function(code) {
      if (code !== 0) console.warn("pi-presence: baseline cleanup failed", code);
    }
  }

  FileView {
    id: registry
    path: service.registryPath
    blockLoading: true
    watchChanges: true
    printErrors: false
    onLoaded: service.apply(text())
    // FileView caches its text: onFileChanged has to force the re-read, and
    // the fresh contents arrive back through onLoaded.
    onFileChanged: registry.reload()
    onLoadFailed: service.setFrame("off")
  }

  // Preferred baseline: the mirror on disk. Its presence means the previous run
  // left the compositor boosted, so the live values are not trustworthy.
  FileView {
    id: persistedBaseline
    path: service.baselinePath
    blockLoading: true
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var b = JSON.parse(text());
        service.baseSize = String(b.border_size ?? "1");
        service.baseBorder = String(b.active_border ?? "");
        service.baseAngleEnabled = Number(b.angle_enabled ?? 0) === 1;
        service.baseAngleBezier = String(b.angle_bezier ?? "default");
        service.baseAngleSpeed = String(b.angle_speed ?? "1");
        service.baselineReady = true;
        if (service.frame !== "off") service.applyWorking();
      } catch (e) {
        captureProcess.running = true;
      }
    }
    onLoadFailed: captureProcess.running = true
  }

  // Fallback baseline: read the live compositor, then mirror it.
  Process {
    id: captureProcess
    command: ["bash", "-c",
      "printf 'SIZE '; hyprctl getoption general:border_size 2>/dev/null | head -1; "
      + "printf 'BORDER '; hyprctl getoption general:col.active_border 2>/dev/null | head -1; "
      + "hyprctl animations 2>/dev/null | grep -A4 'name: borderangle' | grep -m1 'enabled:'; "
      + "hyprctl animations 2>/dev/null | grep -A4 'name: borderangle' | grep -m1 'bezier:'; "
      + "hyprctl animations 2>/dev/null | grep -A4 'name: borderangle' | grep -m1 'speed:'"]
    stdout: SplitParser {
      onRead: function(line) {
        var t = String(line).trim();
        if (t.indexOf("SIZE ") === 0) {
          var n = t.replace("SIZE ", "").match(/int:\s*(\d+)/);
          if (n) service.baseSize = n[1];
        } else if (t.indexOf("BORDER ") === 0) {
          var g = t.replace("BORDER ", "").match(/gradient data:\s*(.+)/);
          if (g) service.baseBorder = g[1].trim();
        } else if (t.indexOf("enabled:") === 0) {
          service.baseAngleEnabled = t.split(/\s+/)[1] === "1";
        } else if (t.indexOf("bezier:") === 0) {
          var b = t.split(/\s+/)[1];
          if (b) service.baseAngleBezier = b;
        } else if (t.indexOf("speed:") === 0) {
          var s = t.split(/\s+/)[1];
          if (s) service.baseAngleSpeed = s;
        }
      }
    }
    onExited: {
      service.baselineReady = true;
      service.persistBaseline();
      if (service.frame === "attention") service.applyAttention();
      else if (service.frame === "working") service.applyWorking();
    }
  }

  // A clean exit restores and drops the mirror; a crash leaves the mirror for
  // the next run to pick up.
  Component.onDestruction: {
    if (service.frame !== "off") service.restoreIdle();
  }
}
