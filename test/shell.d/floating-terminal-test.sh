#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Include spaces in the private profile path and capture argument boundaries,
# so a launch cannot pass by accidentally flattening the shell command.
export OMARCHY_PATH="$ROOT"
export OMARCHY_SESSION_CONFIG_HOME="$tmp_dir/private session"
export KITTY_CONFIG_DIRECTORY="$OMARCHY_SESSION_CONFIG_HOME/kitty"
mkdir -p "$KITTY_CONFIG_DIRECTORY" "$tmp_dir/outside" "$HOME/.config/kitty"
printf 'font_size 11\n' >"$KITTY_CONFIG_DIRECTORY/kitty.conf"
printf 'host profile\n' >"$HOME/.config/kitty/kitty.conf"
printf 'outside profile\n' >"$tmp_dir/outside/kitty.conf"

cat >"$tmp_dir/setsid" <<'SCRIPT'
#!/bin/bash
printf '%s\0' "$@" >"$TEST_LOG"
SCRIPT
chmod +x "$tmp_dir/setsid"

export TEST_LOG="$tmp_dir/log"
export PATH="$tmp_dir:$ROOT/bin:$PATH"

"$ROOT/bin/omarchy-launch-floating-terminal-with-presentation" "printf '%s' 'hello world'"

python3 - <<'PYTHON'
import os
from pathlib import Path
actual = Path(os.environ["TEST_LOG"]).read_bytes().split(b"\0")[:-1]
expected = [
    "uwsm-app", "--", "kitty", "--config",
    os.environ["KITTY_CONFIG_DIRECTORY"] + "/kitty.conf",
    "--class", "org.omarchy.terminal", "bash", "-c",
    "printf '%s' 'hello world'; if (( $? != 130 )); then omarchy-show-done; fi",
]
assert actual == [os.fsencode(argument) for argument in expected], actual
PYTHON
pass "floating terminal passes the exact private profile, class and presentation command"

# Neither a caller-supplied outside profile nor the ordinary host session root
# may reach the process launcher.
rm "$TEST_LOG"
if KITTY_CONFIG_DIRECTORY="$tmp_dir/outside" \
    "$ROOT/bin/omarchy-launch-floating-terminal-with-presentation" 'echo outside' >/dev/null 2>&1; then
  fail "floating terminal refuses a profile outside the private session"
fi
[[ ! -e $TEST_LOG ]] || fail "outside profile is refused before launching"
if OMARCHY_SESSION_CONFIG_HOME="$HOME/.config" KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty" \
    "$ROOT/bin/omarchy-launch-floating-terminal-with-presentation" 'echo host' >/dev/null 2>&1; then
  fail "floating terminal refuses the global host config root"
fi
[[ ! -e $TEST_LOG ]] || fail "global profile is refused before launching"

mv "$KITTY_CONFIG_DIRECTORY" "$KITTY_CONFIG_DIRECTORY.saved"
ln -s "$tmp_dir/outside" "$KITTY_CONFIG_DIRECTORY"
if "$ROOT/bin/omarchy-launch-floating-terminal-with-presentation" 'echo symlink' >/dev/null 2>&1; then
  fail "floating terminal refuses a private directory symlink escaping to a host profile"
fi
[[ ! -e $TEST_LOG ]] || fail "escaping profile symlink is refused before launching"
[[ $(cat "$HOME/.config/kitty/kitty.conf") == 'host profile' ]] || fail "global profile remains unchanged"
[[ $(cat "$tmp_dir/outside/kitty.conf") == 'outside profile' ]] || fail "outside profile remains unchanged"
pass "floating terminal rejects host, outside and escaping-symlink profiles"
