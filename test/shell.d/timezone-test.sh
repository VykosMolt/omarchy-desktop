#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

timezone_menu="$ROOT/bin/omarchy-menu-timezone"

# systemd-timedated carries its own polkit policy, so a bare timedatectl call
# prompts on its own. Reaching for sudo instead would need a passwordless
# sudoers rule, and this port installs nothing into /etc.
grep -Fx 'timedatectl set-timezone "$timezone"' "$timezone_menu" >/dev/null ||
  fail "timezone menu calls timedatectl directly and lets polkit prompt"

! grep -vE '^[[:space:]]*#' "$timezone_menu" | grep -E '\b(sudo|pkexec)\b' >/dev/null ||
  fail "timezone menu escalates by hand instead of leaving it to timedated's polkit policy"

pass "timezone menu changes the timezone through timedated's own authorization"

grep -F 'omarchy-shell -q omarchy.clock refresh' "$timezone_menu" >/dev/null ||
  fail "timezone menu refreshes the namespaced clock IPC target"

pass "timezone menu refreshes clock after timezone changes"
