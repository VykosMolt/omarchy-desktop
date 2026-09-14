#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/bin" "$test_dir/run"
touch "$test_dir/run/wayland-9" "$test_dir/run/wayland-9.lock"

cat >"$test_dir/bin/qs" <<'STUB'
#!/bin/bash
echo "display=[${WAYLAND_DISPLAY:-}] args=[$*]"
STUB
chmod +x "$test_dir/bin/qs"

export PATH="$test_dir/bin:$PATH"
export OMARCHY_PATH="$ROOT"
export XDG_RUNTIME_DIR="$test_dir/run"

# Callers without a display select their config across displays. Unrelated
# filesystem entries must not be guessed as compositor sockets.
output=$(env -u WAYLAND_DISPLAY "$ROOT/bin/omarchy-shell" omarchy.indicators refresh)
[[ $output == "display=[]"* && $output == *"--any-display"* ]] || fail "shell ipc targets its config without guessing a display" "$output"
pass "shell ipc targets its config without guessing a display"

output=$(WAYLAND_DISPLAY=wayland-9 "$ROOT/bin/omarchy-shell" omarchy.indicators refresh)
[[ $output == "display=[wayland-9]"* && $output != *"--any-display"* ]] || fail "shell ipc keeps an existing display" "$output"
pass "shell ipc keeps an existing display"
