import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Pi presence popup: every running Pi session, what it is doing, and a jump to
// its terminal.
//
// The omarchy-presence pi extension writes ~/.cache/pi-presence/sessions.json on
// every state change of every Pi process. This panel watches that file, so it
// needs no IPC of its own and a shell restart comes back to the state it finds
// on disk. BarWidget.qml owns the bar icon and hands this panel the button to
// anchor against.
//
// A session row is one session: its name, its state, the last few things it did
// as bubbles (executing bash, editing, asking a question, waiting for you), and a
// Jump button. Tool and model text is untrusted, so every string that reaches a
// text sink is plain text, control characters stripped, length capped.
Panel {
  id: root
  moduleName: "pi.presence"
  ipcTarget: "pi.presence"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. The popout coordinator and switchPanelFrom both look the
  // panel up by that identity.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var sessions: []
  property int count: 0
  property int live: 0
  property int attention: 0
  // Keyboard and mouse cursor over the session rows: one highlight at a time,
  // as every panel in the kit does.
  property int cursor: 0
  property real nowMs: Date.now()

  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function refresh() {
    statusFile.reload();
  }

  function apply(raw) {
    var frame = Model.parse(raw, Date.now());
    // A torn read parses to nothing: keep the last good frame rather than
    // blanking the list because a write landed mid-parse.
    if (!frame.ok && root.count > 0) return;
    // Reassigning the list rebuilds every delegate, which would reset the
    // cursor and flicker the bubbles on each heartbeat.
    if (JSON.stringify(frame.sessions) !== JSON.stringify(root.sessions)) {
      root.sessions = frame.sessions;
    }
    root.count = frame.count;
    root.live = frame.live;
    root.attention = frame.attention;
    root.cursor = Math.max(0, Math.min(root.cursor, Math.max(0, frame.count - 1)));
  }

  function sessionAt(index) {
    return root.sessions[index] || null;
  }

  // Close first, then focus: the panel holds a Hyprland focus grab while it is
  // open, and a focus request issued under that grab goes nowhere.
  function jump(session) {
    var target = session ? session : root.sessionAt(root.cursor);
    if (!target) return;
    root.close();
    Qt.callLater(function() {
      var argv = Model.jumpCommand(target);
      if (argv[0] === "hyprctl") {
        focusWindow.command = argv;
        focusWindow.running = true;
      } else {
        focusApp.command = argv;
        focusApp.running = true;
      }
    });
  }

  onOpenedChanged: if (opened) {
    root.nowMs = Date.now();
    root.cursor = 0;
    root.refresh();
  }

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

  // Elapsed times tick while the panel is open; the bar icon needs no timer.
  Timer {
    interval: 1000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: focusWindow
    onExited: function(code) {
      // Only a window that closed since the status file was written makes this
      // fail; then bring the terminal forward by its app id.
      if (code !== 0) {
        var session = root.sessionAt(root.cursor);
        focusApp.command = Model.jumpCommand({ address: "", klass: session ? session.klass : "" });
        focusApp.running = true;
      }
    }
  }

  Process {
    id: focusApp
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Anchor under the widget rather than the middle of the bar, so the panel
    // follows wherever the widget is placed.
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(620))

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) {
        if (root.count === 0) return;
        root.cursor = (root.cursor + dy + root.count) % root.count;
      }
      onActivateRequested: root.jump(null)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = t.toLowerCase();
        if (key === "r") root.refresh();
        else if (key === "j") root.jump(null);
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: strings.t("panel.title")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item { Layout.fillWidth: true }

            Text {
              textFormat: Text.PlainText
              text: root.count > 0 ? String(root.count) : ""
              color: root.attention > 0 ? root.urgent : Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          PanelSeparator { foreground: root.foreground }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            visible: root.count === 0

            Text {
              textFormat: Text.PlainText
              text: strings.t("panel.none")
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              Layout.fillWidth: true
            }

            PanelActionButton {
              iconText: Model.glyph("refresh")
              tooltipText: strings.t("panel.refresh")
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              onClicked: root.refresh()
            }
          }

          Repeater {
            model: root.sessions
            delegate: SessionRow {
              required property var modelData
              required property int index
              width: column.width
              session: modelData
              hasCursor: root.cursor === index
              foreground: root.foreground
              accent: root.accent
              urgent: root.urgent
              fontFamily: root.fontFamily
              nowMs: root.nowMs
              strings: strings
              onActivated: root.jump(modelData)
              onHoveredRow: function(isHovered) { if (isHovered) root.cursor = index; }
            }
          }
        }
      }
    }
  }

  // ---- parts ------------------------------------------------------------

  // One status message of a session, drawn as a chat bubble.
  component Bubble: Rectangle {
    id: bubble

    property string text: ""
    property string state: "tool"
    property real ts: 0
    property bool newest: false
    property color foreground: root.foreground
    property color accent: root.accent
    property color urgent: root.urgent
    property string fontFamily: root.fontFamily
    property real nowMs: root.nowMs

    implicitHeight: line.implicitHeight + Style.space(9)
    radius: Style.cornerRadius
    color: Qt.rgba(foreground.r, foreground.g, foreground.b, newest ? 0.11 : 0.05)
    border.width: newest ? 1 : 0
    border.color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.18)

    Behavior on color {
      ColorAnimation { duration: Style.duration(120) }
    }

    RowLayout {
      id: line
      anchors.fill: parent
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: Model.glyph(bubble.state)
        color: Model.tone(bubble.state) === "urgent" ? bubble.urgent
          : (Model.tone(bubble.state) === "accent" ? bubble.accent : Qt.darker(bubble.foreground, 1.5))
        font.family: bubble.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignTop
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: bubble.text
        color: bubble.newest ? bubble.foreground : Qt.darker(bubble.foreground, 1.35)
        font.family: bubble.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        elide: Text.ElideRight
        maximumLineCount: 2
      }

      Text {
        textFormat: Text.PlainText
        text: Model.ago(bubble.ts, bubble.nowMs)
        color: Qt.darker(bubble.foreground, 1.8)
        font.family: bubble.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignTop
      }
    }
  }

  component SessionRow: CursorSurface {
    id: row

    required property var session
    required property bool hasCursor
    property color foreground: root.foreground
    property color accent: root.accent
    property color urgent: root.urgent
    property string fontFamily: root.fontFamily
    property real nowMs: root.nowMs
    property var strings: null

    signal activated()
    signal hoveredRow(bool isHovered)

    implicitHeight: body.implicitHeight + Style.space(14)
    radius: Style.cornerRadius

    readonly property color toneColor: {
      var tone = Model.tone(row.session.state);
      if (tone === "urgent") return row.urgent;
      if (tone === "accent") return row.accent;
      if (tone === "muted") return Qt.darker(row.foreground, 1.3);
      return Qt.darker(row.foreground, 1.6);
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onEntered: row.hoveredRow(true)
      onExited: row.hoveredRow(false)
      onClicked: row.activated()
    }

    ColumnLayout {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(5)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: Model.glyph(row.session.state)
          color: row.toneColor
          font.family: row.fontFamily
          font.pixelSize: Style.font.icon
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: Model.nameOf(row.session)
            color: row.foreground
            font.family: row.fontFamily
            font.pixelSize: Style.font.body
            font.bold: row.hasCursor
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: text !== ""
            text: Model.metaOf(row.session, row.nowMs)
            color: Qt.darker(row.foreground, 1.6)
            font.family: row.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          textFormat: Text.PlainText
          text: Model.ago(row.session.updatedAt, row.nowMs)
          color: Qt.darker(row.foreground, 1.6)
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }

        PanelActionButton {
          iconText: Model.glyph("jump")
          tooltipText: row.strings ? row.strings.t("row.jump") : "Jump"
          foreground: row.foreground
          hoverColor: row.accent
          fontFamily: row.fontFamily
          onClicked: row.activated()
        }
      }

      // The session's own thread: the last few things it did, oldest first.
      Repeater {
        model: Model.threadOf(row.session, 3)
        delegate: Bubble {
          required property var modelData
          required property int index
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(2)
          text: modelData.text
          state: modelData.state
          ts: modelData.ts
          newest: index === 2
          foreground: row.foreground
          accent: row.accent
          urgent: row.urgent
          fontFamily: row.fontFamily
          nowMs: row.nowMs
        }
      }
    }
  }
}
