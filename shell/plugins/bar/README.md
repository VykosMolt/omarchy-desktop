# Omarchy bar

[`Bar.qml`](Bar.qml) is the built-in `omarchy.bar` plugin hosted by the [Omarchy shell](../../README.md). Its configuration comes from the `bar` object in `$OMARCHY_CONFIG_HOME/shell.json`; the initial layout is in [`config/omarchy/shell.json`](../../../config/omarchy/shell.json).

## Layout and controls

`bar.position` accepts `top`, `bottom`, `left` and `right`. `bar.layout.left`, `.center` and `.right` contain objects with a widget `id` and inline settings. `bar.centerAnchor` centers one module precisely and arranges its neighbors around it; an empty value centers the group instead. `bar.transparent` controls the background.

Drag empty bar space, or click and hold it, to move the bar to another edge. Double-click empty center space to toggle transparency. Drag widgets to reorder them. The equivalent scripting interface is `omarchy bar position`, `transparent`, `move` and `set`; use `list`, `put` and `remove` to inspect and change membership.

```json
{
  "version": 1,
  "bar": {
    "position": "top",
    "transparent": false,
    "centerAnchor": "omarchy.clock",
    "layout": {
      "left": [{ "id": "omarchy.menu" }, { "id": "omarchy.workspaces" }],
      "center": [{ "id": "omarchy.clock", "format": "HH:mm" }],
      "right": [{ "id": "omarchy.audio" }, { "id": "omarchy.power" }]
    }
  }
}
```

## Widgets

| Id | Function |
|---|---|
| `omarchy.menu` | Menu and app launcher |
| `omarchy.workspaces` | Hyprland workspace switcher |
| `omarchy.clock` | Time label, calendar and timezones |
| `omarchy.media` | MPRIS playback and cover art |
| `omarchy.indicators` | DND, Stay Awake and other session state |
| `omarchy.sensors` | Hardware readings and power-profile control |
| `omarchy.tray` | Application tray, available to add when needed |
| `omarchy.weather` | Weather and forecast |
| `omarchy.microphone` | Microphone mute and volume |
| `omarchy.audio` | Output volume, devices and app mixer |
| `omarchy.network` | Network status, Wi-Fi and connection settings |
| `omarchy.power` | Battery, profiles and system information |
| `omarchy.bluetooth` | Bluetooth radio and devices |
| `omarchy.monitor` | Brightness and laptop display controls |
| `omarchy.system-monitor` | Window and process management |
| `omarchy.active-window` | Focused window title |
| `omarchy.keyboard-layout` | Active keyboard layout |
| `omarchy.spacer` | Configurable empty space |

`omarchy.indicators.items` selects a subset such as `["Dnd", "StayAwake"]`; omission or an empty array uses the default order. `alwaysShow: true` keeps inactive indicators visible. Multiple indicator instances may show different subsets. Widgets adapt to horizontal and vertical bars; popups open toward the workspace.

## Local modules

Custom modules use `type: "command"` or `type: "qml"` in the same layout. A command module runs `exec` at its `interval` in seconds and accepts `onClick`, `onRightClick` and `onMiddleClick` commands:

```json
{ "id": "custom-status", "type": "command", "exec": "my-status-command", "interval": 5, "tooltip": "Status", "onClick": "my-status-panel" }
```

Commands may print plain text or JSON such as `{"text":"Ready","tooltip":"Job finished","class":"active"}`.

A QML entry such as `{"id":"custom-status","type":"qml"}` loads `$OMARCHY_CONFIG_HOME/bar/modules/custom-status.qml`. Set `source` to use an explicit path. The module should be an `Item` with `implicitWidth` and `implicitHeight`; it may declare `bar`, `moduleName` and `settings`, which the host injects.

Widgets can read `bar.foreground`, `bar.background`, `bar.urgent`, `bar.fontFamily`, `bar.position`, `bar.vertical` and `bar.barSize`. `bar.run(command)` executes a Bash command; quote interpolated arguments with `Util.shellQuote`. `bar.requestPopout(owner)` and `bar.releasePopout(owner)` coordinate popup ownership. Shared tooltips use `bar.showTooltip(target, text)` and `bar.hideTooltip(target)`; the target exposes `tooltipHovered` while its pointer is inside.

Prefer shared controls from `qs.Ui` when adding widgets so input forwarding, disabled state, tooltips and orientation follow the rest of the bar.
