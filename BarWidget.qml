import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Pi presence, bar side: the π icon, and the host for the session popup.
//
// Shape contract, as `panels/clock/BarWidget.qml` implements it: the bar owns
// the widget mounted in its slot, and identifies a panel by that widget — the
// popout coordinator, `Panels.openPanelByModule`, `shell.togglePanelAt` and the
// open-panel dot all resolve through this root. So `opened`, `open()`,
// `close()`, `togglePanel()`, `closeForPopoutSwitch()` and `popoutSwitchClosing`
// are forwarded to the panel, and the panel gets `bar`, `settings` and
// `anchorItem` injected. A popup declared inside the bar widget never maps: the
// panel registry never sees it, so nothing can open it.
//
// The omarchy-presence pi extension writes ~/.cache/pi-presence/sessions.json on
// every state change of every Pi process. This widget watches it, so bar and
// popup need no IPC of their own and a shell restart comes back to the state it
// finds on disk.
BarWidget {
  id: root
  moduleName: "pi.presence"

  property int count: 0
  property int live: 0
  property int attention: 0
  property string primary: "idle"

  readonly property color barForeground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color barColor: count === 0
    ? Qt.darker(barForeground, 1.9)
    : (attention > 0 ? Commons.Color.urgent : (live > 0 ? Commons.Color.accent : barForeground))
  readonly property string barTooltip: {
    if (count === 0) return strings.t("panel.none");
    var out = strings.tn("panel.sessions", count).arg(count);
    if (live > 0) out += " · " + strings.tn("panel.working", live).arg(live);
    if (attention > 0) out += " · " + strings.t("bar.attention");
    return out;
  }

  function refresh() {
    statusFile.reload();
    var item = panelLoader.item;
    if (item && item.refresh) item.refresh();
  }

  function apply(raw) {
    var frame = Model.parse(raw, Date.now());
    // A torn read parses to nothing: keep the last good frame rather than
    // blanking the bar because a write landed mid-parse.
    if (!frame.ok && root.count > 0) return;
    root.count = frame.count;
    root.live = frame.live;
    root.attention = frame.attention;
    root.primary = frame.sessions.length > 0 ? frame.sessions[0].state : "idle";
  }

  // ---- Panel host ---------------------------------------------------------

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open();
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close();
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle();
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch();
  }

  function injectPanel() {
    var target = panelLoader.item;
    if (!target) return;
    if ("bar" in target) target.bar = root.bar;
    if ("settings" in target) target.settings = root.settings;
    if ("anchorItem" in target) target.anchorItem = button;
    if ("hostWidget" in target) target.hostWidget = root;
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  FileView {
    id: statusFile
    path: Quickshell.env("HOME") + "/.cache/pi-presence/sessions.json"
    blockLoading: true
    watchChanges: true
    printErrors: false
    onLoaded: root.apply(text())
    // FileView caches its text, so a change event has to force the re-read;
    // the fresh contents arrive back through onLoaded.
    onFileChanged: statusFile.reload()
    onLoadFailed: root.apply("")
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel();
      Qt.callLater(root.injectPanel);
    }
  }

  ShellIpc {
    target: "pi.presence"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barGlyph(root.live > 0, root.attention > 0)
    foreground: root.barColor
    tooltipText: root.barTooltip

    Behavior on foreground {
      ColorAnimation { duration: Style.duration(120) }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.close();
      else root.togglePanel();
    }
  }

  // A lit icon that is working and a lit icon that is idle read the same at a
  // glance, so the working state gets a pulse of its own.
  Rectangle {
    id: liveDot
    x: button.x + button.width - width - Style.space(3)
    y: button.y + Style.space(3)
    width: Style.space(5)
    height: Style.space(5)
    radius: Style.space(3)
    visible: root.live > 0 || root.attention > 0
    color: root.attention > 0 ? Commons.Color.urgent : Commons.Color.accent

    SequentialAnimation on opacity {
      running: visible && root.live > 0
      loops: Animation.Infinite
      NumberAnimation { from: 1.0; to: 0.25; duration: Style.duration(700); easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.25; to: 1.0; duration: Style.duration(700); easing.type: Easing.InOutSine }
    }
    opacity: root.live > 0 ? 1.0 : 0.75
  }
}
