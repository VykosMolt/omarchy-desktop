# First-party plugins

These components ship with the port and are discovered from this directory
through their `manifest.json` files. Non-bar components are enabled unless listed
in `disabledPlugins`; `omarchy.bar` is the default full bar. Services and
keep-loaded components mount at startup. Other panels, overlays and menus load
when summoned.

All user paths follow the session's isolated roots from
[`lib/omarchy-paths.sh`](../../lib/omarchy-paths.sh); QML accesses those roots
through `qs.Commons.Paths`. Shell configuration lives under
`$OMARCHY_CONFIG_HOME/shell.json`, current theme state under
`$OMARCHY_STATE_HOME/current/theme`, and cached assets under
`$OMARCHY_CACHE_HOME`. These are the roots exported by the dedicated session.

| Plugin | ID | Kinds | Entry points |
|---|---|---|---|
| Audio | `omarchy.audio` | `bar-widget` | `panels/audio/Panel.qml` |
| Background | `omarchy.background` | `service` | `background/Background.qml` |
| Bar | `omarchy.bar` | `bar` | `bar/Bar.qml` |
| Battery | `omarchy.battery` | `service` | `services/battery/Service.qml` |
| Bluetooth | `omarchy.bluetooth` | `bar-widget` | `panels/bluetooth/Panel.qml` |
| Clipboard | `omarchy.clipboard` | `overlay` | `clipboard/Clipboard.qml` |
| Clock | `omarchy.clock` | `bar-widget` | `panels/clock/BarWidget.qml` |
| Display | `omarchy.monitor` | `bar-widget` | `panels/monitor/Panel.qml` |
| Emojis | `omarchy.emojis` | `overlay` | `emojis/Emojis.qml` |
| Idle | `omarchy.idle` | `service` | `services/idle/Service.qml` |
| Image picker | `omarchy.image-picker` | `overlay` | `image-picker/ImagePicker.qml` |
| Lock Screen | `omarchy.lock` | `service` | `lock/Service.qml` |
| Media | `omarchy.media` | `service`, `bar-widget` | `services/media/Service.qml`, `services/media/BarWidget.qml` |
| Network | `omarchy.network` | `bar-widget` | `panels/network/Panel.qml` |
| Notifications | `omarchy.notifications` | `service` | `notifications/Service.qml` |
| Omarchy menu | `omarchy.menu` | `menu`, `bar-widget` | `menu/Menu.qml`, `menu/BarWidget.qml` |
| On-screen display | `omarchy.osd` | `panel` | `osd/Osd.qml` |
| Power | `omarchy.power` | `bar-widget` | `panels/power/Panel.qml` |
| Settings | `omarchy.settings` | `panel` | `panels/settings/Panel.qml` |
| Speed Test | `omarchy.speedtest` | `panel` | `panels/speedtest/Panel.qml` |
| System monitor | `omarchy.system-monitor` | `bar-widget` | `panels/system-monitor/Panel.qml` |
| Weather | `omarchy.weather` | `bar-widget` | `panels/weather/BarWidget.qml` |
| Wi-Fi QR | `omarchy.wifiqr` | `panel` | `panels/wifiqr/Panel.qml` |

Individual bar widgets also have manifests beside their QML files, for example
`bar/widgets/Workspaces.manifest.json`. The bar layout lives in the top-level
`bar` object in `shell.json`; the default is
[`config/omarchy/shell.json`](../../config/omarchy/shell.json). See
[`bar/README.md`](bar/README.md) for widget configuration.

## Image picker

The fullscreen image carousel serves wallpaper/theme selection and callers
that supply image directories or prepared rows. Thumbnails come from the
session's `image-selector` cache.

- `omarchy-shell shell summon omarchy.image-picker '<jsonPayload>'` accepts
  `imageDirs`, `imageRows`, `selectedImage`, `selectionFile`, `doneFile`,
  `showLabels`, and `filterable`.
- `omarchy-shell image-selector open <imageDirs> <imageRowsB64> <selectedImage>
  <selectionFile> <doneFile> <showLabels> <filterable>` carries the same inputs
  through positional IPC. Prepared rows are base64 encoded to preserve tabs
  and newlines.

Callers provide private selection and completion paths. A successful selection
writes the chosen image path and creates the completion file. Cancel completes
the request without writing a selection. A superseded or canceled asynchronous
scan cannot reopen the carousel. The keep-loaded window is reused across
summons.

## Menu and settings

The menu uses `menu/Menu.qml` inside the long-running shell. Its definition
combines `default/omarchy/omarchy-menu.jsonc` with
`$OMARCHY_CONFIG_HOME/extensions/omarchy-menu.jsonc`. File watches reload changes;
condition expressions run in a batched subprocess and a selected action runs
through the shell's command execution path.

`omarchy-shell shell toggle omarchy.settings` opens Settings, also reachable
under Setup in the menu. Idle timings and bar layout are shell configuration;
appearance settings, monitor scaling and Stay Awake are backed by existing
commands. Writes serialize, then reread the actual value. Failed write messages
remain visible through that reread and clear after a successful retry.

## Network and system monitor

The network panel provides Wi-Fi, DNS, band selection and the configured VPN controls. Enterprise Wi-Fi setup and authentication repair open `nm-connection-editor`, where the network's EAP method, certificate and server settings can be configured. Saved enterprise profiles connect normally; the panel never collects enterprise credentials or creates an incomplete profile. If the editor is unavailable, the network row identifies the missing command. Its Wi-Fi sharing panel is `omarchy.wifiqr`; passwords are read only on deliberate reveal and cleared on dismissal. `omarchy.speedtest` runs download and upload measurements and stops its traffic when dismissed.

The system monitor lists windows, background applications and processes. Ending
uses SIGTERM after confirmation. Force kill is offered only for the exact
process identities previously sent SIGTERM; PID reuse and new group members
cannot inherit that action. The sampler's process start time accompanies each
PID through confirmation to the signal helper.

## Lock screen

The lock service uses Quickshell's native `WlSessionLock` with separate host
PAM profiles: `omarchy-lock-password`, and `omarchy-lock-fingerprint` when
fingerprints are configured. The password profile must exist before the
service accepts a lock request; its status reports `missing-pam` otherwise.
PAM configuration belongs to the host and is not installed by the shell.
