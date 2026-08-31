# omarchy-desktop

The Omarchy Quattro desktop — Hyprland with the Quickshell shell, bar, launcher,
notifications, lock screen and theming — running as one ordinary session on a
stock Arch Linux install, alongside whatever else is already there.

Keep the desktop. Delete the distro.

Omarchy's operating-system layer is not part of this port. There is no
installer, no migrations, no release channels or self-update, no package
install/remove wrappers, no account provisioning, no factory reset, and nothing
that edits `/etc`, PAM, sudoers or the bootloader. The desktop keeps its own
config, state, cache and data under `~/.config/omarchy-arch` and its siblings;
`HOME` and the XDG directories are left alone.

## Running it

`bin/omarchy-arch-session` is the session entry point, published to the display
manager through `default/wayland-sessions/omarchy-arch.desktop`. It sources
`~/omarchy-arch-port/runtime/env.sh`, links the `omarchy-arch-*` user units,
takes an advisory lock that keeps those units out of any other Hyprland session
on the account, and starts `Hyprland --config` against the isolated config.

## Layout

- `bin/` — the `omarchy-*` commands and the `omarchy` CLI router
- `shell/` — the Quickshell desktop (bar, menu, panels, lock, notifications)
- `default/hypr/` — Hyprland defaults loaded at config-parse time
- `default/omarchy/omarchy-menu.jsonc` — the launcher definition
- `default/systemd/user/` — the session's own units
- `config/` — shipped defaults for the isolated config root
- `themes/`, `default/themed/` — theme palettes and the templates they fill
- `docs/` — how the shell, menu, theming and notifications are put together

## Upstream

Ported from [Omarchy](https://github.com/basecamp/omarchy) at
`56fbaf4689e3eb6867c0b7f375ae49964f183774`. Licensed under the MIT License; see
[LICENSE](LICENSE).
