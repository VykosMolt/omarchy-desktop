#!/bin/bash

# Coverage for omarchy-system-signal, which is how the system monitor ends a
# process or a whole application.
#
# Every process this touches is one it started itself. A signal test must never
# name a pid it did not create: the pids that look convenient -- the service
# manager, the compositor -- are the ones that end the session.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

SIGNAL="$ROOT/bin/omarchy-system-signal"

started=()

cleanup() {
  (( ${#started[@]} > 0 )) || return 0
  "$SIGNAL" --signal KILL "${started[@]}" 2>/dev/null || true
}
trap cleanup EXIT

# Sets `spawned` rather than printing the pid: a command substitution would run
# this in a subshell, where the cleanup list would not survive and the pipe the
# background process inherits would keep the substitution waiting on it.
spawned=""

spawn() {
  sleep 120 >/dev/null 2>&1 &
  spawned=$!
  local start_time
  start_time=$(python3 - "$spawned" <<'PYTHON'
import sys
with open(f"/proc/{sys.argv[1]}/stat") as source:
    raw = source.read()
print(raw[raw.rfind(")") + 1:].split()[19])
PYTHON
  )
  started+=("$spawned:$start_time")
}

[[ -x $SIGNAL ]] || fail "the command ships executable"
pass "the command ships executable"

for bad in 1 0 -5 12.5 "12; rm -rf ~" "" ; do
  if "$SIGNAL" --signal TERM "$bad" >/dev/null 2>&1; then
    fail "a pid that is not a plain number above 1 is refused" "$bad was accepted"
  fi
done
pass "a pid that is not a plain number above 1 is refused"

if "$SIGNAL" --signal HUP 4242 >/dev/null 2>&1; then
  fail "only TERM and KILL are accepted"
fi
pass "only TERM and KILL are accepted"

if "$SIGNAL" --signal TERM >/dev/null 2>&1; then
  fail "a call with no process to signal is refused"
fi
pass "a call with no process to signal is refused"

spawn
live=$spawned
"$SIGNAL" --signal TERM "$live" || fail "signalling a process this test started succeeds"
for _ in {1..20}; do
  kill -0 "$live" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$live" 2>/dev/null; then
  fail "SIGTERM reaches the process"
fi
pass "SIGTERM reaches the process"

# Ending an app ends the process the others depended on, so by the time the
# rest are signalled some of them have already gone. `kill` on the whole list
# exits non-zero for that, which reported a successful quit as a failure.
spawn
alive=$spawned
spawn
gone=$spawned
kill -9 "$gone" 2>/dev/null || true
wait "$gone" 2>/dev/null || true

"$SIGNAL" --signal TERM "$alive" "$gone" ||
  fail "a process that has already exited does not fail the group"
pass "a process that has already exited does not fail the group"

for _ in {1..20}; do
  kill -0 "$alive" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$alive" 2>/dev/null; then
  fail "the rest of the group is still signalled"
fi
pass "the rest of the group is still signalled"

"$SIGNAL" --signal TERM "$alive" "$gone" ||
  fail "a group that has entirely exited is the outcome that was asked for"
pass "a group that has entirely exited is the outcome that was asked for"

# An identity from an older incarnation of the PID cannot signal the live one.
spawn
identity_pid=$spawned
identity=$(python3 - "$identity_pid" <<'PYTHON'
import sys
with open(f"/proc/{sys.argv[1]}/stat") as source:
    raw = source.read()
print(raw[raw.rfind(")") + 1:].split()[19])
PYTHON
)
"$SIGNAL" --signal TERM "$identity_pid:$((identity + 1))" || fail "stale identities are harmless"
kill -0 "$identity_pid" || fail "a stale identity signalled a different process"
if "$SIGNAL" --signal TERM "$identity_pid:$identity" "0:123" >/dev/null 2>&1; then
  fail "the complete target vector is validated before signalling"
fi
kill -0 "$identity_pid" || fail "a malformed vector partially terminated a process"
"$SIGNAL" --signal TERM "$identity_pid:$identity" || fail "an exact identity can be signalled"
wait "$identity_pid" 2>/dev/null || true
pass "start-time identities refuse PID reuse and malformed vectors before delivery"

# Exercise permission errors without naming a real process this test does not
# own. In PID namespaces PID 2 is not necessarily kthreadd, and may not exist.
python3 - "$SIGNAL" <<'PYTHON'
import os
import signal
import sys
from pathlib import Path
code = Path(sys.argv[1]).read_text().split("<<'PYTHON'\n", 1)[1].rsplit("\nPYTHON", 1)[0]
closed = []
os.pidfd_open = lambda pid: 123
os.close = closed.append

def refuse(*args):
    raise PermissionError("fixture")
signal.pidfd_send_signal = refuse
sys.argv = ["omarchy-system-signal", "--signal", "TERM", "4242"]
try:
    exec(compile(code, "omarchy-system-signal", "exec"))
except SystemExit as result:
    assert result.code and "4242" in str(result.code), result.code
else:
    raise AssertionError("permission failure passed silently")
assert closed == [123], closed
PYTHON
pass "permission failures are reported without touching unrelated processes"

if grep -qE 'sudo|pkexec' "$SIGNAL"; then
  fail "signalling asks for no privilege"
fi
pass "signalling asks for no privilege"
