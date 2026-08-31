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

Credit where it is due, and there is real credit to give.

`omarchy-theme-set` refuses to stage `*.lua`, `kitty.conf` or `vscode.json` out
of a cloned theme, because each of those is arbitrary code execution wearing a
colour palette — Hyprland `require`s a theme's `hyprland.lua` at login, and
`kitty.conf` names the program your terminal launches. It filters at staging
rather than at install, so themes that predate the rule are covered too. That is
someone thinking properly about a threat model most projects never notice.

`Util.execArgv` passes untrusted values as positional parameters through a
constant `exec "$@"`, so a filename containing `$(id)` stays a filename. The
comment explains why. Whoever wrote that has been bitten before and learned the
right lesson.

Even the sudoers decision I am rudest about below comes with a paragraph of
honest reasoning attached. The disagreement here is about where a desktop's
authority ends, not about whether anyone was paying attention.

## Who this is for

You already run Arch. You already have a Hyprland config you have opinions about,
a browser you chose on purpose, and a DNS server you set for a reason. You looked
at Omarchy, liked the desktop, and did not love that installing it means handing
over the machine.

That is the entire audience. If you want the batteries-included experience —
installer, curated packages, sensible defaults chosen for you, updates that
arrive on their own — then you want [Omarchy](https://github.com/basecamp/omarchy)
proper, and it is very good at that. This is for people who want the top half and
already have the bottom half, thanks.

## What it runs on

Built and used daily on **Arch Linux**. Nothing in it is Arch-specific: no package
manager is invoked anywhere, nothing is installed or removed, and `/etc` is never
written. `omarchy-remove-launcher-entry` will delete a launcher entry you own and
politely refuse to touch one a package installed, which is the closest the whole
tree comes to having an opinion about your distribution.

What it actually needs:

- **Hyprland** and **Quickshell** — the compositor and the shell it draws
- **systemd**, for the user units the session brings up
- **uwsm** and `start-hyprland`, which the session launcher goes through
- a display manager that reads `wayland-sessions`, or any other way you like to
  start a session

So it should work on any systemd distribution that packages Hyprland and
Quickshell. It has only been tested on Arch, and anything else is a claim rather
than a promise. If you run it somewhere else and it breaks, that is a bug report
I would enjoy reading.

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

## Everything that changed

Grouped by the problem each commit was solving, rather than listed as a log.

### Making it a guest instead of an owner

Omarchy keeps its config, state, cache and data in `~/.config/omarchy` and its
siblings, and writes Hyprland's config to `~/.config/hypr`. Install it beside an
existing Hyprland setup and it lands on top of one you already had. The session
also started user units by fixed names, so two Hyprland sessions on one account
would fight over the same shell.

Everything now lives under `~/.config/omarchy-arch` and friends, resolved through
one helper (`lib/omarchy-paths.sh`, plus its Lua and QML equivalents) rather than
hardcoded in each of the fifty-odd places that needed it. The session brings up
its own `omarchy-arch-*` units and takes an advisory `flock`, so whichever
session starts first owns the shell and the other stands down.

### Removing the operating system

The installer, migrations, release channels, self-update, package install and
remove wrappers, account provisioning, factory reset, the agent and screensaver
layers, the Trigger menu family, preinstalled application and web-app bindings,
per-application theming, the curated app rules, and the LocalSend integration.

Then the parts that were less obvious:

- **The theme marketplace.** `theme-install` cloned arbitrary git repositories,
  with `theme-update`, `theme-extras` and a URL checker in support. Theme
  *switching* stayed; the shop closed.
- **The plugin ecosystem.** Third-party plugins and clone-replacement machinery,
  109 lines of registry logic that nothing could reach any more: the scan only
  ever looks at first-party plugins, so every branch behind "is this
  third-party?" was dead. `shell.qml` was still handling `onLocalPluginChanged`,
  a signal that had stopped existing, and Qt warned about it at every start.
- **The setup-task tracker**, which recorded which onboarding steps you had
  completed for an onboarding flow that no longer exists.
- **Hook directories for events that cannot happen** — `post-update.d` ("after an
  Omarchy system update") and `pre-refresh-pacman.d` (called by `omarchy refresh
  pacman`, writes `/etc/pacman.conf`).
- **The acceptance suite**, which tested that the machine was a correctly
  provisioned Omarchy install: every package in a manifest, Chromium as your
  browser, Nautilus for directories, cups-browsed hardening, absence from the
  docker group. On a machine that chose differently it could only fail. It now
  checks the desktop instead.

### The privilege surface

This is the part that most deserves a long look, because it is the least visible
and the hardest to reverse once it is on a machine.

Omarchy ships five sudoers drop-ins. Three are narrow and defensible: passwordless
`timedatectl set-timezone` behind a regex, a browser-policy command behind a
six-hex-digit pattern, and `omarchy-dns` restricted to three exact invocations.
Fine. That is how you write a NOPASSWD rule.

The other two are not that.

```
%wheel ALL=(ALL) NOPASSWD: /usr/bin/asdcontrol
```

No argument constraint, and `(ALL)` rather than `(root)`. Every member of `wheel`
may run a USB HID tool as any user on the system, with any arguments, without a
password, forever — installed for the benefit of people with an Apple Studio
Display.

```
Defaults passwd_tries=10
```

That is not scoped to Omarchy. It raises sudo's password-attempt allowance from
three to ten for **every sudo invocation on the machine**, permanently, because
typing your password is annoying. A desktop should not get to make that call.

And then the one that ties it together — opt-in, this one, for people hacking on
Omarchy itself rather than anyone who merely installed it. `omarchy dev link
<checkout>` writes `/etc/sudoers.d/omarchy-dev-path`, which prepends that
checkout's `bin/` to sudo's `secure_path` — so root resolves bare command names
out of a directory the unprivileged user can write to. The reasoning is in the source and it is honest
about what it is doing: it wants `sudo omarchy-*` to run the code you are
editing.

The trouble is that `secure_path` exists precisely to stop root resolving
commands out of user-controlled directories, and a NOPASSWD rule pointing at
`/usr/bin/omarchy-dns` does not save you when `omarchy-dns` then calls `tee`,
`nmcli`, `install` and `rm` by bare name as root. Omarchy knows this — every
privileged script pins `PATH` by hand when `EUID == 0`, with a comment explaining
why. That defence works. It is also a thing you have to remember to write, in
every privileged script, every time, forever, and it is one forgotten line away
from a local root.

None of this is catastrophic on its own, and none of it is careless in the sense
of nobody having thought about it. It is what happens when a desktop is also the
thing that owns the machine: every convenience gets to reach for root, and the
reaching accumulates.

This port ships no `etc/` directory at all. Nothing it contains needs a sudoers
rule, because nothing it contains edits the system.

### Things that were quietly wrong

- **`omarchy-dns` owned `/etc`.** To point you at Cloudflare it wrote a whole new
  `/etc/systemd/resolved.conf` — no backup, no merge, whatever you had in there
  is gone — and then walked every saved NetworkManager profile rewriting
  `ipv4.dns` and `ipv6.dns`. All fifteen of mine, including the ones for networks
  I was not on and had not asked about. NetworkManager has a polkit action for
  exactly this, scoped to a connection, which the desktop can call as you rather
  than as root. That is what it does now, and the sudoers rule went with it.
- **Four commands built a filesystem path out of an argument** without checking
  it, and then wrote to it, deleted it, or executed it. `omarchy-hook
  ../../../../pwned` ran a script four directories above the hooks directory;
  `omarchy-hyprland-toggle ../../../../../victim off` deleted a `.lua` file five
  above the toggles one. One shared rule now rejects any name containing a
  slash, and `.` and `..` besides — while leaving `...` and `..foo` alone,
  because those are ordinary filenames and somebody will have one.
- **Three ways a login came up with nothing** — a blank session, fixed.
- **A surface that was present, correctly sized, and painting nothing.** The
  wallpaper read its path from the stock state directory, which no longer
  existed after isolation, so it rendered an empty layer. There is now a test
  that catches a surface which claims to be drawing and is not.
- **A restart that restarted nothing.** `omarchy-restart-shell` discarded the
  result of its kill, so when the kill matched nothing the readiness ping was
  answered by the shell it had failed to stop, and it reported success. A shell
  survived several restarts this way, which made "the bar still works" prove
  nothing about the code it was supposedly running.
- **The launcher ignored your icon theme.** It walked icon roots in filesystem
  order, so `steam` resolved to whichever theme `find` reached first while
  Papirus sat unread. Papirus also builds its large sizes out of symlinks, which
  `find` does not follow without `-L`: 51,954 visible icons became 122,156.
- **`omarchy-default-terminal` returned an empty string,** because it asked
  `xdg-terminal-exec --print-id` and swallowed the failure when that turned out
  to be a local shim that only knows how to exec kitty.
- **One indicator shadowed `QQuickItem.state`**, quietly breaking a property Qt
  itself uses, and a single tab character in a command line froze the system
  monitor outright.
- **Code that could not run at all.** The dictation indicator read
  `omarchy-voxtype-status`, which short-circuits to a static `idle` when voxtype
  is not installed — so its `active: mode === "recording"` could never be true
  and the indicator could never appear. Nothing was broken, exactly; it just was
  not anything.

### Making it faster

- **The menu's guard batch: 87ms to 14ms.**
- **Every bar action went through a login shell.** `Util.execDetached` ran
  `bash -lc`, which sources `/etc/profile`, every script in `/etc/profile.d` and
  your `.bashrc` before the command starts. Measured at **123ms**, paid in full
  by a workspace click whose entire job was to hand one line to `hyprctl`. That
  cost is real when you are launching a GUI application, which needs the session
  environment — so the login shell stayed for that, and a direct-exec path was
  added for tools that need nothing from your profile.
- **Wallpapers were decoded at eight times the screen's resolution.** A wallpaper
  is compressed on disk and uncompressed in memory: `3-sunset-lake.webp` is 356KB
  of WebP and 7680×3215 pixels, which is **94MB of RGBA** on a display that can
  show 16MB of it. No `sourceSize` was set, so Qt decoded all of it — across
  three `Image` elements at once, two of them building mipmaps on top. That was
  most of several hundred megabytes of graphics buffers, for one photograph.
- **The icon index catalogued 227,100 files to answer 153 questions.** The icon
  theme spec has each theme list its own directories in `index.theme`, so the
  tree never needed walking: 413ms became 84ms, byte-identical output.
- **NVIDIA's GL stack was mapped into a bar rendering on Intel.** glvnd loads
  every installed EGL vendor to ask which one claims the device. Naming Mesa for
  the shell process alone: 246MB PSS to 225MB, 495MB RSS to 382MB.
- **The tray held 100MB of applets drawing nothing** — nm-applet and blueman
  duplicating bar widgets that already existed, plus fcitx5 for a single
  configured input method.
- **`SUPER+T` took 385ms** because it woke the discrete GPU to ask a question it
  could answer from sysfs.

### Fitting the hardware it actually runs on

Kitty is the only terminal shipped, so the three others went. Hardware support
for hardware this is not. The discrete GPU is left asleep unless something
genuinely wants it.

### Keeping it honest

Every `bin/` command is checked for a summary header. The shell is linted with
Qt6's `qmllint` — not the `qmllint` on `PATH`, which is Qt5's and will cheerfully
report failures that are not there. Both suites run with a sandboxed `HOME` and
with every Omarchy `bin/` taken off `PATH`, so a test that hides a command cannot
find a sibling checkout's copy instead. Nothing that reads the code is allowed to
draw on your screen while doing it.

**101 test files, 1,935 assertions.**

## Upstream

Ported from [Omarchy](https://github.com/basecamp/omarchy) at
`56fbaf4689e3eb6867c0b7f375ae49964f183774`, with its history intact — every
commit here that predates the port is someone else's good work. MIT licensed;
see [LICENSE](LICENSE).

Sincere thanks to DHH and the Omarchy contributors for the desktop. Sorry about
the distro.
