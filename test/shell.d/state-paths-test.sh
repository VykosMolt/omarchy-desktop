#!/bin/bash

set -euo pipefail

# The wallpaper rendered nothing for as long as this port has existed, and
# nothing caught it. Background.qml built its own path:
#
#   readonly property string stateHome: home + "/.local/state"
#   readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
#
# That is stock Omarchy's location. The isolated session keeps state wherever
# OMARCHY_STATE_HOME points, so the lookup read a directory that does not exist,
# the Image had no source, and a transparent panel showed the compositor's fill.
# No error, no warning, and every geometry-based check still passed.
#
# Paths already resolves this correctly and every one of these files already
# imported it. Four had built the path by hand anyway: the wallpaper, the lock
# screen background, the image picker's fallback directory, and the bar watching
# the wrong current/ for theme changes.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

offenders=$(grep -rn '"/omarchy/current\|"/\.local/state\|"/\.config/omarchy' \
  "$ROOT/shell" --include='*.qml' --include='*.js' 2>/dev/null |
  grep -v 'Commons/Paths.qml' || true)

[[ -z $offenders ]] ||
  fail "no shell surface builds an Omarchy state or config path by hand" "$offenders"
pass "no shell surface builds an Omarchy state or config path by hand"

# Paths is the only place allowed to read the roots from the environment.
env_readers=$(grep -rln 'Quickshell.env("OMARCHY_\(STATE\|CONFIG\|CACHE\|DATA\)_HOME")' \
  "$ROOT/shell" --include='*.qml' --include='*.js' 2>/dev/null |
  grep -v 'Commons/Paths.qml' || true)

[[ -z $env_readers ]] ||
  fail "the state roots are read through Paths, not from the environment directly" "$env_readers"
pass "the state roots are read through Paths, not from the environment directly"

for f in shell/plugins/background/Background.qml shell/plugins/lock/Service.qml; do
  grep -q 'Paths.omarchyState' "$ROOT/$f" ||
    fail "$(basename "$(dirname "$f")")/$(basename "$f") resolves its background through Paths"
done
pass "the wallpaper and the lock screen both resolve their background through Paths"

runtime_tmp=$(mktemp -d)
trap 'rm -rf "$runtime_tmp"' EXIT
source "$ROOT/lib/omarchy-paths.sh"
OMARCHY_CACHE_HOME="$runtime_tmp/cache"
unset XDG_RUNTIME_DIR
runtime=$(omarchy_runtime_dir)
[[ $runtime == "$OMARCHY_CACHE_HOME/runtime" && -d $runtime ]] || fail "runtime fallback is scoped to the session cache"
[[ $(stat -c %a "$runtime") == 700 ]] || fail "runtime fallback is private"
[[ $(omarchy_runtime_dir) == "$runtime" ]] || fail "runtime fallback is stable across calls"
pass "runtime fallback is private and stable"

mkdir "$runtime_tmp/session"
[[ $(XDG_RUNTIME_DIR="$runtime_tmp/session" omarchy_runtime_dir) == "$runtime_tmp/session" ]] || fail "runtime helper honors the session directory"
chmod 777 "$runtime_tmp/session"
if XDG_RUNTIME_DIR="$runtime_tmp/session" omarchy_runtime_dir >/dev/null 2>&1; then
  fail "runtime helper refuses a directory writable by other users"
fi
chmod 700 "$runtime_tmp/session"
if XDG_RUNTIME_DIR="$runtime_tmp/missing" omarchy_runtime_dir >/dev/null 2>&1; then
  fail "runtime helper refuses an invalid explicit directory"
fi
mkdir "$runtime_tmp/other-cache"
ln -s "$runtime_tmp/session" "$runtime_tmp/other-cache/runtime"
if OMARCHY_CACHE_HOME="$runtime_tmp/other-cache" omarchy_runtime_dir >/dev/null 2>&1; then
  fail "runtime fallback refuses symlinks"
fi
pass "runtime helper rejects invalid and redirected directories"

# Exercise first-use initialization through its real getters and file writers.
# No graphical or host-setting command may escape these temporary roots.
python3 - <<'PYTHON'
import configparser
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

repo = Path(os.environ["ROOT"])
with tempfile.TemporaryDirectory(prefix="omarchy init ") as directory:
    root = Path(directory)
    stubs = root / "bin"
    stubs.mkdir()
    scripts = {
        "fc-match": '''#!/bin/bash
[[ ${INIT_FAIL_FONT:-0} == 1 ]] && exit 1
if [[ -n ${INIT_FONT_BARRIER:-} ]]; then
  touch "$INIT_FONT_BARRIER/ready"
  while [[ ! -e $INIT_FONT_BARRIER/release ]]; do sleep 0.02; done
fi
printf '%s\\n' "${INIT_FONT:-Initial Mono}"
''',
        "xdg-settings": '#!/bin/bash\n[[ $1 == get ]] || exit 99\nprintf "%s\\n" "${INIT_BROWSER:-}"\n',
        "xdg-mime": '#!/bin/bash\n[[ $1 == query ]] || exit 99\nprintf "%s\\n" "${INIT_BROWSER:-}"\n',
    }
    for command in ("gsettings", "hyprctl", "systemctl", "omarchy-notification-send", "omarchy-reload-terminal", "omarchy-hook"):
        scripts[command] = '#!/bin/bash\ntouch "$INIT_MUTATION"\nexit 99\n'
    for name, content in scripts.items():
        path = stubs / name
        path.write_text(content)
        path.chmod(0o755)

    def fixture(name):
        base = root / name
        home = base / "home"
        (home / ".config/gtk-3.0").mkdir(parents=True)
        (home / ".config/gtk-3.0/settings.ini").write_text(
            "[Settings]\ngtk-icon-theme-name=Initial Icons\ngtk-cursor-theme-name=Initial Cursor\ngtk-cursor-theme-size=27\n")
        env = os.environ.copy()
        env.update(HOME=str(home), OMARCHY_PATH=str(repo),
                   PATH=str(stubs) + ":" + str(repo / "bin") + ":" + env["PATH"],
                   DBUS_SESSION_BUS_ADDRESS="", INIT_MUTATION=str(base / "mutation"),
                   INIT_FONT="Initial Mono", INIT_BROWSER="initial.desktop")
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env.pop("XDG_" + kind + "_HOME", None)
            session = base / (kind.lower() + " with spaces")
            env["OMARCHY_SESSION_" + kind + "_HOME"] = str(session)
            env["OMARCHY_" + kind + "_HOME"] = str(session / "omarchy")
        env["KITTY_CONFIG_DIRECTORY"] = str(Path(env["OMARCHY_SESSION_CONFIG_HOME"]) / "kitty")
        return base, env

    def run(env, ok=True):
        result = subprocess.run([str(repo / "bin/omarchy-arch-session-init")], env=env,
                                text=True, capture_output=True, timeout=15)
        assert (result.returncode == 0) == ok, result.stderr
        assert not Path(env["INIT_MUTATION"]).exists(), "initialization signalled or mutated host services"
        return result

    def prefs(env):
        settings = configparser.ConfigParser()
        settings.read(Path(env["OMARCHY_CONFIG_HOME"]) / "appearance.ini")
        return settings

    def bytes_under(path):
        return {str(p.relative_to(path)): p.read_bytes() for p in path.rglob("*") if p.is_file()}

    base, env = fixture("fresh")
    host_before = bytes_under(base / "home")
    run(env)
    p = prefs(env)
    assert dict(p["Icons"]) == {"theme": "Initial Icons"}
    assert dict(p["Cursor"]) == {"theme": "Initial Cursor", "size": "27"}
    assert p["Font"]["Family"] == "Initial Mono"
    defaults = Path(env["OMARCHY_STATE_HOME"]) / "defaults"
    assert (defaults / "browser").read_text() == "initial.desktop\n"
    assert (defaults / "terminal").read_text() == "kitty\n"
    kitty = Path(env["KITTY_CONFIG_DIRECTORY"]) / "kitty.conf"
    assert "font_family Initial Mono\n" in kitty.read_text()
    assert "include ${OMARCHY_STATE_HOME}/current/theme/kitty.conf\n" in kitty.read_text()
    assert bytes_under(base / "home") == host_before
    print("ok - fresh initialization snapshots preferences and creates only private config/state")

    # Parse with Kitty itself when available: an absent palette must be harmless,
    # and a later palette at a path containing spaces must actually take effect.
    if shutil.which("kitty"):
        parser = '''import json, os
from kitty.config import load_config
bad = []
opts = load_config(os.environ["KITTY_CONFIG_DIRECTORY"] + "/kitty.conf", accumulate_bad_lines=bad)
print(json.dumps([len(bad), opts.font_size, int(opts.background)]))'''
        def parse_kitty():
            result = subprocess.run(["kitty", "+runpy", parser], env=env, text=True, capture_output=True, timeout=15)
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        assert parse_kitty()[:2] == [0, 9.0]
        palette = Path(env["OMARCHY_STATE_HOME"]) / "current/theme/kitty.conf"
        palette.parent.mkdir(parents=True)
        palette.write_text("background #123456\n")
        assert parse_kitty() == [0, 9.0, 0x123456]
        print("ok - Kitty accepts a missing palette and follows its private palette with spaces in the path")

    kitty.write_text(kitty.read_text() + "# user edit\nfont_size 12.5\n")
    (defaults / "browser").write_text("user-chosen.desktop\n")
    before = bytes_under(base)
    env.update(INIT_FONT="Later Host Mono", INIT_BROWSER="later.desktop")
    host = base / "home/.config/gtk-3.0/settings.ini"
    host.write_text("[Settings]\ngtk-icon-theme-name=Later Icons\ngtk-cursor-theme-name=Later Cursor\ngtk-cursor-theme-size=48\n")
    before[str(host.relative_to(base))] = host.read_bytes()
    run(env)
    assert bytes_under(base) == before, "repeat initialization changed saved data"
    print("ok - repeat initialization preserves all private files despite later host changes")

    base, env = fixture("partial")
    appearance = Path(env["OMARCHY_CONFIG_HOME"]) / "appearance.ini"
    appearance.parent.mkdir(parents=True)
    appearance.write_text("# keep comment\n[Font]\nFamily=Chosen Mono\n[Unknown]\nValue=keep\n[Cursor]\nSize=37\n")
    kitty = Path(env["KITTY_CONFIG_DIRECTORY"]) / "kitty.conf"
    kitty.parent.mkdir(parents=True)
    kitty.write_bytes(b"# existing profile without theme linkage\nfont_size 15\n")
    kitty_before = kitty.read_bytes()
    run(env)
    assert prefs(env)["Cursor"]["Size"] == "37" and prefs(env)["Font"]["Family"] == "Chosen Mono"
    assert prefs(env)["Unknown"]["Value"] == "keep" and appearance.read_text().startswith("# keep comment\n")
    assert kitty.read_bytes() == kitty_before
    kitty.unlink()
    run(env)
    assert "font_family Chosen Mono\n" in kitty.read_text()
    print("ok - partial preferences retain existing keys/comments and new Kitty uses the private font")

    base, env = fixture("no browser")
    env["INIT_BROWSER"] = ""
    run(env)
    env["INIT_BROWSER"] = "later.desktop"
    (base / "home/.config/mimeapps.list").write_text("[Default Applications]\nx-scheme-handler/https=later.desktop\n")
    run(env)
    result = subprocess.run([str(repo / "bin/omarchy-default-browser"), "--desktop"], env=env, capture_output=True)
    assert result.returncode == 0 and result.stdout == b"\n"
    result = subprocess.run([str(repo / "bin/omarchy-launch-browser")], env=env, capture_output=True)
    assert result.returncode == 1 and b"No Omarchy browser is selected" in result.stderr
    assert not Path(env["INIT_MUTATION"]).exists()
    print("ok - an empty browser snapshot remains empty and launching fails without host fallback")

    base, env = fixture("failure")
    env["INIT_FAIL_FONT"] = "1"
    run(env, ok=False)
    assert prefs(env)["Icons"]["Theme"] == "Initial Icons"
    assert not (Path(env["KITTY_CONFIG_DIRECTORY"]) / "kitty.conf").exists()
    env["INIT_FAIL_FONT"] = "0"
    (base / "home/.config/gtk-3.0/settings.ini").write_text("[Settings]\ngtk-icon-theme-name=Later Icons\n")
    run(env)
    assert prefs(env)["Icons"]["Theme"] == "Initial Icons"
    assert prefs(env)["Font"]["Family"] == "Initial Mono"
    print("ok - failure recovery completes missing values without resetting completed snapshots")

    base, env = fixture("missing template")
    checkout = base / "checkout"
    checkout.mkdir()
    for part in ("bin", "lib"):
        (checkout / part).symlink_to(repo / part)
    env["OMARCHY_PATH"] = str(checkout)
    run(env, ok=False)
    kitty = Path(env["KITTY_CONFIG_DIRECTORY"]) / "kitty.conf"
    assert not kitty.exists(), "failed rendering published an empty profile"
    (checkout / "config").symlink_to(repo / "config")
    run(env)
    assert "font_family Initial Mono\n" in kitty.read_text()
    print("ok - an unavailable Kitty template leaves no partial profile and retry can complete")

    base, env = fixture("concurrent")
    barrier = base / "barrier"
    barrier.mkdir()
    env["INIT_FONT_BARRIER"] = str(barrier)
    first = subprocess.Popen([str(repo / "bin/omarchy-arch-session-init")], env=env, stderr=subprocess.PIPE)
    second = None
    try:
        deadline = time.monotonic() + 5
        while not (barrier / "ready").exists():
            assert first.poll() is None and time.monotonic() < deadline, "first initialization failed to reach font lookup"
            time.sleep(.02)
        other_env = dict(env, INIT_FONT="Second Mono")
        other_env.pop("INIT_FONT_BARRIER")
        second = subprocess.Popen([str(repo / "bin/omarchy-arch-session-init")], env=other_env, stderr=subprocess.PIPE)
        time.sleep(.1)
        assert second.poll() is None, "a competing initializer bypassed the lock"
        (barrier / "release").touch()
        assert first.communicate(timeout=5)[1] == b"" and first.returncode == 0
        assert second.communicate(timeout=5)[1] == b"" and second.returncode == 0
        assert prefs(env)["Font"]["Family"] == "Initial Mono"
    finally:
        for proc in (first, second):
            if proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait()
    print("ok - concurrent initialization serializes and preserves the first completed choices")

    # Redirections are rejected during preflight, even when the root itself
    # is a symlink. The outside target must be completely unchanged.
    for target in ("session config", "session state", "config root", "state root", "kitty directory", "kitty file", "appearance", "appearance lock", "init lock", "defaults", "browser", "terminal", "palette"):
        base, env = fixture("symlink " + target)
        outside = base / "outside"
        outside.mkdir()
        sentinel = outside / "sentinel"
        sentinel.write_text("keep\n")
        config = Path(env["OMARCHY_CONFIG_HOME"])
        state = Path(env["OMARCHY_STATE_HOME"])
        destinations = {
            "session config": Path(env["OMARCHY_SESSION_CONFIG_HOME"]),
            "session state": Path(env["OMARCHY_SESSION_STATE_HOME"]),
            "config root": config, "state root": state,
            "kitty directory": Path(env["KITTY_CONFIG_DIRECTORY"]),
            "kitty file": Path(env["KITTY_CONFIG_DIRECTORY"]) / "kitty.conf",
            "appearance": config / "appearance.ini", "appearance lock": config / "appearance.ini.lock",
            "init lock": config / "session-init.lock", "defaults": state / "defaults",
            "browser": state / "defaults/browser", "terminal": state / "defaults/terminal",
            "palette": state / "current/theme/kitty.conf",
        }
        dest = destinations[target]
        dest.parent.mkdir(parents=True, exist_ok=True)
        is_directory = target in ("session config", "session state", "config root", "state root", "kitty directory", "defaults")
        dest.symlink_to(outside if is_directory else sentinel)
        before = bytes_under(outside)
        run(env, ok=False)
        assert bytes_under(outside) == before, target
        assert not (config / "appearance.ini").exists() or target == "appearance", target
    for kind in ("CONFIG", "STATE"):
        base, env = fixture("global " + kind)
        path = base / ("home/.config" if kind == "CONFIG" else "home/.local/state")
        env["OMARCHY_SESSION_" + kind + "_HOME"] = str(path)
        env["OMARCHY_" + kind + "_HOME"] = str(path / "omarchy")
        before = bytes_under(base / "home")
        run(env, ok=False)
        assert bytes_under(base / "home") == before
    print("ok - host roots and symlink escapes are rejected before preference writes")
PYTHON
