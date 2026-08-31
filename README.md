# omarchy-desktop

The Omarchy Quattro desktop — Hyprland, the Quickshell bar, launcher, notifications,
lock screen and theming — running as one ordinary session on a stock Arch install,
politely, next to everything else you already have.

**Keep the desktop. Delete the distro.**

Omarchy is two things wearing one trenchcoat: a genuinely lovely desktop, and an
operating system that would like to have opinions about your bootloader. This is
the top half.

## What went in the bin

No installer. No migrations. No release channels, no self-update, no package
wrappers, no factory reset, and nothing that edits `/etc`, PAM, sudoers or your
boot config. Also gone: the theme marketplace, the plugin ecosystem, the
onboarding checklist, and a small colony of preinstalled app shortcuts for
software you do not have.

The command that best explains why: to change your DNS, `omarchy-dns` used to
write a whole new `/etc/systemd/resolved.conf` — no backup — and then rewrite the
DNS settings on **every saved NetworkManager profile you own**. All fifteen of
mine. It now asks NetworkManager, like a guest.

## What stayed

Nearly all of it, because the desktop half is good:

- the Quickshell bar, its panels, and the launcher
- notifications, OSD, the lock screen, idle handling, clipboard history, media
- the theme engine and its templates
- Hyprland configured in Lua, which is nicer than it sounds

Credit where it is due: `omarchy-theme-set` refuses to stage `*.lua`,
`kitty.conf` or `vscode.json` out of a cloned theme, because each of those is
arbitrary code execution wearing a colour palette. That is careful work and it
is kept verbatim.

## Running it

`bin/omarchy-arch-session` is the entry point, published to your display manager
via `default/wayland-sessions/omarchy-arch.desktop`. It sources
`~/omarchy-arch-port/runtime/env.sh`, links the `omarchy-arch-*` user units, takes
an advisory lock so it cannot trample another Hyprland session on the same
account, and starts `Hyprland --config` against its own isolated config.

Your `HOME` and XDG directories are left exactly as they were. The desktop keeps
its config, state, cache and data under `~/.config/omarchy-arch` and friends, so
if you hate it you can delete four directories and pretend this never happened.

## Layout

- `bin/` — the `omarchy-*` commands and the `omarchy` CLI router
- `shell/` — the Quickshell desktop (bar, menu, panels, lock, notifications)
- `default/hypr/` — Hyprland defaults loaded at config-parse time
- `default/omarchy/omarchy-menu.jsonc` — the launcher definition
- `default/systemd/user/` — the session's own units
- `config/` — shipped defaults for the isolated config root
- `themes/`, `default/themed/` — theme palettes and the templates they fill
- `docs/` — how the shell, menu, theming and notifications fit together
- `test/` — 101 files, 1935 assertions, and a strong opinion about login shells

## Upstream

Ported from [Omarchy](https://github.com/basecamp/omarchy) at
`56fbaf4689e3eb6867c0b7f375ae49964f183774`, with its history intact — every
commit here that predates the port is someone else's good work. MIT licensed;
see [LICENSE](LICENSE).

Sincere thanks to DHH and the Omarchy contributors for the desktop. Sorry about
the distro.
