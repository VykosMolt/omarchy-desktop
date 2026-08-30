import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "WorkspacesModel.js" as WorkspacesModel

BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  // The row is rebuilt from scratch whenever this array's identity changes, so
  // it is replaced only when the ids really differ. WorkspacesModel carries the
  // reasoning and the tests.
  property var ids: [1, 2, 3, 4, 5]
  property var byId: ({})

  // Tracked as a binding so the dependency is declared, rather than guessed at
  // through a signal name on the model object.
  readonly property var liveWorkspaces: Hyprland.workspaces.values
  onLiveWorkspacesChanged: root.refreshWorkspaces()

  function refreshWorkspaces() {
    var values = root.liveWorkspaces || []
    root.byId = WorkspacesModel.byId(values)
    root.ids = WorkspacesModel.stableIds(root.ids, WorkspacesModel.workspaceIds(values))
  }

  Component.onCompleted: root.refreshWorkspaces()

  // Straight down the socket this widget already holds open for
  // Hyprland.workspaces. It used to go out through bar.run, which is
  // `bash -lc` -- a login shell, sourcing /etc/profile, fifteen
  // /etc/profile.d scripts and the user's .bashrc, then exec'ing hyprctl to
  // open a second socket -- 128ms per click against 5.8ms for the same
  // command without the login shell, and effectively nothing for this. That
  // is why SUPER+N felt instant and clicking the bar did not: the keybind is
  // compiled into Hyprland once at config load and dispatched in-process,
  // while the click rebuilt the same expression as a string every time.
  //
  // The expression is the one tiling.lua binds, deliberately, so the bar and
  // the keyboard cannot drift apart.
  function focusWorkspace(id) {
    Hyprland.dispatch("hl.dsp.focus({ workspace = \"" + id + "\" })")
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.ids.length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.ids

      WidgetButton {
        required property int modelData

        readonly property var workspace: root.byId[modelData] || null
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData

        bar: root.bar
        text: focused ? "\uDB85\uDCFB" : (modelData === 10 ? "0" : String(modelData))
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(modelData) }
      }
    }
  }
}
