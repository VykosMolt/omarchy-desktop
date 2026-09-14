# Omarchy desktop for an existing Arch system

This is the desktop portion of Omarchy Quattro: Hyprland, the Quickshell bar and panels, launcher, notifications, lock screen, clipboard, and themes. It runs as an isolated session alongside the host's existing desktop configuration.

The port does not provide an operating-system installer, package management, migrations, self-updates, boot configuration, account provisioning, or PAM/sudoers setup. It uses the services and applications already configured on the host.

## Running this checkout

`bin/omarchy-arch-session` reads `~/omarchy-arch-port/runtime/env.sh` and starts `start-hyprland` through `uwsm`, with `--config` pointing at the isolated Hyprland configuration. The display-manager entry is `default/wayland-sessions/omarchy-arch.desktop`; its launcher path must already exist on the host. This repository does not install it.

The runtime environment defines `OMARCHY_PATH` and the session's config, state, cache, and data roots. The local setup uses:

| Content | Root |
|---|---|
| Configuration | `~/.config/omarchy-arch` |
| Persistent state | `~/.local/state/omarchy-arch` |
| Cache | `~/.cache/omarchy-arch` |
| Data | `~/.local/share/omarchy-arch` |

The corresponding variables are `OMARCHY_SESSION_{CONFIG,STATE,CACHE,DATA}_HOME`. Omarchy's own files use the `omarchy/` subdirectory through `OMARCHY_{CONFIG,STATE,CACHE,DATA}_HOME`. `HOME` and the host's XDG variables retain their normal values.

The session takes an advisory lock before changing runtime state. Its systemd user services require that lock and read a private session environment file. The launcher removes its environment and compositor drop-in when the session ends. Services are linked at runtime, not enabled permanently.

## Desktop controls

- The bar contains workspaces, clock, keyboard layout, weather, hardware sensors, system monitor, Bluetooth, network, audio, display, and power controls.
- The system monitor shows application groups and processes, with CPU/memory sorting, filtering, focus, close, and confirmed process termination.
- Settings exposes the controls supported by this desktop. Hyprland overrides remain editable in the isolated `hypr/` directory.
- Themes provide palettes and desktop/Kitty templates. Wallpaper folders and icon themes are configured independently.
- The lock screen uses the host's available PAM configuration. This port does not create authentication policy.

Default bindings are in `default/hypr/bindings/`; personal bindings in the isolated configuration load afterward. Use `omarchy menu keybindings --print` to inspect the active keymap.

Useful commands, from a session with `OMARCHY_PATH` set:

```bash
omarchy                          # command groups
omarchy commands --all           # complete command list
omarchy menu summon setup.settings
omarchy theme list
omarchy theme set tokyo-night
omarchy bar list
omarchy shell shell ping
omarchy restart shell
```

An isolated shell restart stays under `omarchy-arch-shell.service`. Restart refuses to interrupt a secure lock screen; recovery of a stranded compositor lock waits for the replacement locker to become secure.

## Dependencies

The core session expects Hyprland with the Lua configuration API, Quickshell with Qt 6, systemd user services, `uwsm`, `start-hyprland`, Bash 5, coreutils, util-linux, Python 3, and jq. Kitty is the shipped terminal integration. NetworkManager, PipeWire/WirePlumber, BlueZ, and power-profiles-daemon back their respective controls; capture and optional hardware actions use additional commands checked by those helpers.

This setup is used on Arch Linux. Other distributions and older Hyprland/Quickshell releases have not been validated. The local `runtime/env.sh` also contains this laptop's integrated-GPU selection; that hardware choice is separate from the repository's defaults.

## Development and verification

Read [AGENTS.md](AGENTS.md) for the session isolation and implementation contracts.

```bash
./test/all                        # CLI and shell/model tests
```

Tests isolate user state and use stubs for commands that change the desktop. Graphical fixture tests skip when no compositor is available. `./test/acceptance` is separate and drives a dedicated graphical test session; it opens windows, changes settings temporarily, and captures screenshots.

See [testing](docs/testing.md), [CLI routing](docs/cli-router.md), [shell architecture](docs/omarchy-shell.md), [menu configuration](docs/menu.md), [theming](docs/theming.md), and [notifications](docs/notifications.md).

## Layout and origin

- `bin/`, `lib/`: desktop commands and shared shell helpers.
- `shell/`: Quickshell host, shared controls, services, and built-in plugins.
- `config/`, `default/`: shipped user configuration, Hyprland defaults, systemd units, templates, and menu data.
- `themes/`: palettes and supported desktop overrides.
- `test/`, `docs/`: verification and interface documentation.

Ported from [Omarchy](https://github.com/basecamp/omarchy) at `56fbaf4689e3eb6867c0b7f375ae49964f183774`, retaining upstream history. MIT licensed; see [LICENSE](LICENSE).
