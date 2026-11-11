import QtQuick

// Offscreen stand-in for qs.Ui's KeyboardPanel.
//
// KeyboardPanel is a Quickshell PopupWindow, and a layer-shell popup has no
// backend under QT_QPA_PLATFORM=offscreen, so the harness swaps this in: the
// same properties, the same content contract, a plain Item. The content
// component is instantiated, so the panel's rows, bubbles and bindings are all
// exercised, which is where QML mistakes surface.
Item {
  id: stub

  property Item anchorItem: null
  property var owner: null
  property QtObject bar: null
  property bool open: false
  property bool centerOnBar: false
  property int margin: 0
  property int padding: 0
  property int gap: 0
  property int contentWidth: 280
  property int contentHeight: 200
  property int contentX: 0
  property int contentY: 0
  property Item focusTarget: null
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property Component content: null

  readonly property Item loadedContent: loader.item
  readonly property real loadedContentHeight: loader.item ? loader.item.implicitHeight : 0

  signal closed()

  function fittedContentWidth(preferred, cap) {
    return cap !== undefined && Number(cap) > 0 ? Math.min(preferred, cap) : preferred
  }

  function fittedContentHeight(implicitHeight, cap) {
    var desired = Math.max(1, Number(implicitHeight) || 1)
    return cap !== undefined && Number(cap) > 0 ? Math.min(desired, cap) : desired
  }

  function cappedContentHeight(height) { return Math.max(1, Number(height) || 1) }
  function ensureContent() {}
  function beginFocusPrime() {}
  function close() { stub.closed() }

  implicitWidth: contentWidth
  implicitHeight: contentHeight
  visible: open

  Loader {
    id: loader
    sourceComponent: stub.content
    width: stub.contentWidth
    height: stub.contentHeight
  }
}
