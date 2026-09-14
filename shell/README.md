# Omarchy shell

`omarchy-shell` is the session's long-running Quickshell host. The bar, menus, panels, background, lock screen and notification server share this process and its services. The session supplies `OMARCHY_PATH`; shell code reads isolated configuration, state and cache roots through [`Commons/Paths.qml`](Commons/Paths.qml).

## Configuration

The host watches `$OMARCHY_CONFIG_HOME/shell.json`. If that file is absent or invalid, it uses [`config/omarchy/shell.json`](../config/omarchy/shell.json), with a small built-in fallback if the shipped file also cannot load. A valid user file is the complete configuration; settings are not deep-merged with the shipped defaults.

```json
{
  "version": 1,
  "idle": { "screenOff": 0, "lock": 300, "suspend": 0 },
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

- `version` must be `1`.
- `bar.id` selects the full bar; omission selects `omarchy.bar`.
- `bar.layout.left`, `.center` and `.right` contain widget instances. Settings live directly beside each entry's `id`. Repeated instances require the widget's `allowMultiple` metadata.
- `plugins[]` holds inline settings for non-bar plugins. Built-in services and panels are enabled by default; `disabledPlugins[]` disables them. Removing a bar widget removes its placement while keeping the feature available to the shell.
- `idle.screenOff`, `idle.lock` and `idle.suspend` are seconds since the user last interacted. Zero disables that stage.

Use `omarchy bar ...` to change bar settings and placement. See the [bar guide](plugins/bar/README.md) for gestures and custom modules.

## Plugin loading

[`services/PluginRegistry.qml`](services/PluginRegistry.qml) scans manifests under `$OMARCHY_PATH/shell/plugins`, including feature directories and sibling `*.manifest.json` files for simple bar widgets. Discovery is limited to this checkout. The [plugin catalogue](plugins/README.md) lists the bundled features.

Each manifest declares `schemaVersion: 1`, `id`, `name`, `version`, `kinds` and `entryPoints`. Entry points are relative to the manifest directory. Supported kind-to-entry-point mappings are:

| Kind | Entry point |
|---|---|
| `bar` | `bar` |
| `bar-widget` | `barWidget` |
| `panel` | `panel` |
| `overlay` | `overlay` |
| `menu` | `menu` |
| `service` | `service` |

Services and `keepLoaded: true` panels load at startup. Other panels load on demand. The host supplies supported properties such as `shell`, `omarchyPath`, `manifest`, `pluginRegistry` and `barWidgetRegistry`; widgets receive `bar`, `moduleName` and their inline `settings`. A summoned panel exposes `open(payloadJson)` and `close()` and can expose `opened` so the host tracks its own close gestures.

The host shares pending loads, discards obsolete completions and releases unloaded components. A plugin rescan waits for an active lock to unlock before rebuilding services.

## IPC

The `omarchy-shell` helper addresses the running host:

```bash
omarchy-shell shell ping
omarchy-shell shell listPlugins
omarchy-shell shell listShellConfig
omarchy-shell shell summon omarchy.menu '{"menu":"system"}'
omarchy-shell shell toggle omarchy.settings ''
omarchy-shell shell hide omarchy.menu
omarchy-shell shell reloadConfig
omarchy-shell shell rescanPlugins
```

Menu helpers and the image picker use file-based selection responses. Each request supplies its own selection and completion paths; cancelling releases the caller without a selection. Prefer the existing `omarchy-menu-*` helpers when calling from scripts.

## Shared code and checks

`Commons/` contains the session paths, theme, geometry and utility singletons. `Ui/` contains shared controls and panel surfaces. Lowercase `services/` holds the host's registries and app library; persistent feature services live under `plugins/`.

Run `./test/shell` from the checkout for shell checks. The registry and notification scheduler also run against Qt in isolated offscreen fixtures. Tests that require actual Wayland surfaces remain separate from these checks.
