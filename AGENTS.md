# Omarchy Arch Port

This repository is the Omarchy Quattro desktop — Hyprland plus the Quickshell
shell — ported to run as one ordinary session on a stock Arch Linux install. It
is not a distribution and it does not own the machine.

Everything Omarchy used to do as an operating system has been removed: the
installer, migrations, release channels and self-update, package install/remove
wrappers, account provisioning, host security setup (PAM, sudoers, SSHD, docker
group), bootloader and Plymouth configuration, and the files it wrote into
`/etc`. Do not reintroduce any of it. A change that installs a package, edits a
file outside the session's own roots, or asks for root to do something other
than a narrowly scoped hardware operation does not belong here.

# Session Isolation

The session runs from `bin/omarchy-arch-session`, which sources
`~/omarchy-arch-port/runtime/env.sh` and launches `Hyprland --config` against
the isolated config root. `HOME` and the XDG variables stay untouched; Omarchy's
own state is redirected instead:

- `OMARCHY_SESSION_{CONFIG,STATE,CACHE,DATA}_HOME` — `~/.config/omarchy-arch` and friends
- `OMARCHY_{CONFIG,STATE,CACHE,DATA}_HOME` — the `omarchy/` directory under each of those

`lib/omarchy-paths.sh` is the shell contract for those variables and
`default/hypr/paths.lua` the Lua one; `shell/Commons/Paths.qml` is the QML one.
Read paths from them. Never hardcode `~/.config/omarchy`, `~/.local/state/omarchy`
or `/usr/share/omarchy` — those belong to a packaged Omarchy install that does
not exist here.

The session holds an advisory flock on `$XDG_RUNTIME_DIR/omarchy-arch-session.lock`
for its whole lifetime. The `omarchy-arch-*` units in `default/systemd/user/`
refuse to start unless that lock is held, so the other Hyprland session on this
account never runs them. Do not weaken that, and do not enable any of those
units permanently.

# Style

- In markdown documents, write full lines — no hard wrapping at 80 columns; break only at structural boundaries like headings and list items
- Two spaces for indentation, no tabs
- Use bash 5 conditionals: use `[[ ]]` for string/file tests and `(( ))` for numeric tests
- In `[[ ]]`, don't quote variables, but do quote string literals when comparing values (e.g., `[[ $branch == "dev" ]]`)
- Prefer `(( ))` over numeric operators inside `[[ ]]` (e.g., `(( count < 50 ))`, not `[[ $count -lt 50 ]]`)
- Prefer a full `if`/`else` conditional for simple two-path control flow; don't rely on `exec` or `exit` in one branch to make following statements unreachable
- For strings/paths with spaces, quote them instead of escaping spaces with `\ `
- Shebangs must use `#!/bin/bash` consistently (never `#!/usr/bin/env bash`)

# Command Naming

All commands start with `omarchy-`. Prefixes indicate purpose. The authoritative
list of user-facing groups lives in `bin/omarchy` in `GROUP_DESCRIPTIONS`; keep
it in step when adding or removing a prefix. A group whose commands are all
`# omarchy:hidden=true` gets no entry.

Surviving prefixes include `audio-`, `bar-`, `bluetooth-`, `brightness-`,
`capture-`, `clipboard-`, `cmd-`, `hw-`, `hyprland-`, `launch-`, `menu-`,
`network-`, `notification-`, `plugin-`, `system-`, `theme-`, `toggle-` and
`weather-`. `install-`, `remove-`, `update-`, `pkg-`, `refresh-`, `provision-`,
`apply-`, `migrate-`, `channel-`, `version-` and `dev-` were the distro layer
and are gone.

# Runtime Environment

- `$OMARCHY_PATH` points at this checkout and is set by the session launcher, the per-service `EnvironmentFile`, and `hl.env()` in `default/hypr/envs.lua`.
- Commands in `bin/` and Quickshell QML should rely on `$OMARCHY_PATH` / `Quickshell.env("OMARCHY_PATH")`; do not derive fallback paths from `HOME` or `Quickshell.shellDir`.

# Privileged Commands

Prefer no privilege at all. Where a desktop action genuinely needs it for a
narrow hardware or system operation, escalate through `sudo` when the caller has
a terminal to type a password into and `pkexec` otherwise, and re-exec this
checkout's own script rather than a packaged path. Never rely on a passwordless
sudoers rule, and never grant a group (such as `docker`) that is root-equivalent.

# Git

- Commits should be atomic: include only one coherent change or fix, and do not mix unrelated work.
- Commit messages should be succinct and describe the change being made.

# Helper Commands

- `omarchy-cmd-missing` / `omarchy-cmd-present` - check for commands
- `omarchy-notification-send` - send desktop notifications; do not call `notify-send` directly
- `omarchy-hw-*` - hardware detection, returning exit codes for use in conditionals

# Menu

- The menu definition lives in `default/omarchy/omarchy-menu.jsonc`; [`docs/menu.md`](docs/menu.md) covers the schema, guards, and providers.
- Guards run in one batched shell; only `omarchy-cmd-present` / `omarchy-cmd-missing` are shimmed inside it. Nothing may ask what packages are installed.
- Do not add `aliases` to new menu entries. Aliases are reserved for established alternate names users already type.

# Config Structure

- `config/` - the port's own shipped defaults (`hypr/`, `omarchy/shell.json`)
- `default/hypr/` - Hyprland defaults loaded at config-parse time
- `default/themed/*.tpl` - templates with `{{ variable }}` placeholders for theme colors
- `themes/*/colors.toml` - theme color definitions

# Tests

- `./test/all` - aggregate runner for CLI and shell tests; it does not run graphical acceptance tests
- `./test/cli` - CLI routing, command metadata, theme helpers, and safe dispatch coverage
- `./test/shell` - all shell tests under `test/shell.d/`

New tests live in `test/shell.d/*-test.sh`. Source `test/shell.d/base-test.sh`
for shared root-path discovery, assertions, and Node test helpers.
