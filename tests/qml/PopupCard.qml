import QtQuick

// Offscreen stand-in for qs.Ui's PopupCard.
//
// PopupCard is a Quickshell PopupWindow, and a layer-shell popup has no backend
// under QT_QPA_PLATFORM=offscreen, so the test harness swaps this in: the same
// properties, a plain Item. It exists so the real widget file can be loaded in
// the harness and its bindings exercised, which is where QML mistakes surface.
Item {
  id: stub

  property QtObject anchorItem: null
  property QtObject owner: null
  property QtObject bar: null
  property bool open: false
  property string triggerMode: "onPress"
  property alias contentWidth: content.width
  property alias contentHeight: content.height
  property alias contentX: content.x
  property alias contentY: content.y

  signal closed()

  function fittedContentWidth(preferred) { return preferred }
  function fittedContentHeight(preferred, maximum) { return Math.min(preferred, maximum) }
  function switchPanel(direction) {}

  implicitWidth: content.width
  implicitHeight: content.height

  Item {
    id: content
  }
}
