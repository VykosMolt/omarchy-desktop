#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const utilQml = fs.readFileSync(path.join(root, 'shell/Commons/Util.qml'), 'utf8')

assert(
  /function execDetached\(command\)[\s\S]*Quickshell\.execDetached\(\["bash", "-lc", command\]\)/.test(utilQml),
  'detached command helper uses a login shell'
)

JS

# Exercise process identity filtering with real processes, not a pkill stub.
# Two processes have the same comm and differ only in desktop/session identity.
ROOT="$ROOT" python3 - <<'PYTHON'
import os
import subprocess
import tempfile
from pathlib import Path

root = Path(os.environ['ROOT'])
with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    env = os.environ.copy()
    env.update(HOME=str(base/'home'), OMARCHY_PATH=str(root),
               OMARCHY_SESSION_CONFIG_HOME=str(base/'session'),
               KITTY_CONFIG_DIRECTORY=str(base/'session'/'kitty'),
               HYPRLAND_INSTANCE_SIGNATURE='omarchy-fixture')
    (base/'session'/'kitty').mkdir(parents=True)
    child = '''import ctypes, signal, sys, time
ctypes.CDLL(None).prctl(15, b"kitty", 0, 0, 0)
def received(*args):
    print("reloaded", flush=True)
signal.signal(signal.SIGUSR1, received)
print("ready", flush=True)
while True: time.sleep(1)
'''
    private = subprocess.Popen(['python3', '-c', child], env=env, stdout=subprocess.PIPE, text=True)
    host_env = env | {'HYPRLAND_INSTANCE_SIGNATURE': 'plasma-fixture'}
    host = subprocess.Popen(['python3', '-c', child], env=host_env, stdout=subprocess.PIPE, text=True)
    try:
        assert private.stdout.readline().strip() == 'ready'
        assert host.stdout.readline().strip() == 'ready'
        subprocess.run([str(root/'bin/omarchy-restart-terminal')], env=env, check=True)
        import select
        assert select.select([private.stdout], [], [], 2)[0], 'private Kitty was not reloaded'
        assert private.stdout.readline().strip() == 'reloaded'
        assert not select.select([host.stdout], [], [], 0.1)[0], 'host Kitty was signalled'
    finally:
        for process in (private, host):
            process.terminate()
            process.wait(timeout=3)
print('ok - terminal reload targets only the matching Omarchy process identity')
PYTHON

# Terminal and TUI launch bypass the host xdg-terminal preference and pass the
# private Kitty profile directly. Every launcher sees only test command stubs.
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/session/kitty"
export OMARCHY_PATH="$ROOT" OMARCHY_SESSION_CONFIG_HOME="$fixture/session"
export KITTY_CONFIG_DIRECTORY="$fixture/session/kitty" TERMINAL_LAUNCH_LOG="$fixture/launch"
cat >"$fixture/bin/setsid" <<'STUB'
#!/bin/bash
exec "$@"
STUB
cat >"$fixture/bin/uwsm-app" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$TERMINAL_LAUNCH_LOG"
STUB
cat >"$fixture/bin/omarchy-cmd-terminal-cwd" <<'STUB'
#!/bin/bash
printf /tmp
STUB
chmod +x "$fixture/bin/"*
PATH="$fixture/bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-launch-terminal" echo hello
grep -qxF "$fixture/session/kitty/kitty.conf" "$TERMINAL_LAUNCH_LOG" || fail "terminal launcher selects the private Kitty profile"
PATH="$fixture/bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-launch-tui" --app-id=org.omarchy.fixture echo hello
grep -qxF org.omarchy.fixture "$TERMINAL_LAUNCH_LOG" || fail "TUI launcher preserves its app class"
grep -qxF "$fixture/session/kitty/kitty.conf" "$TERMINAL_LAUNCH_LOG" || fail "TUI launcher selects the private Kitty profile"
pass "terminal launchers use the private Kitty profile directly"
