#!/bin/bash

# Process identities for private runtime records. Callers own their record paths.
# All control goes through a recorded kernel identity. The pidfd pins the
# target across the stat check and signal; an exited/reused PID is inactive.
omarchy_signal_session_processes() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && -n ${OMARCHY_PATH:-} && -n ${OMARCHY_SESSION_CONFIG_HOME:-} ]] || return 0
  python3 - "$1" "$2" <<'PYTHON'
import os
import signal
import sys
from pathlib import Path

name, requested_signal = sys.argv[1:]
required = ("OMARCHY_PATH", "OMARCHY_SESSION_CONFIG_HOME", "HYPRLAND_INSTANCE_SIGNATURE")
if name == "kitty":
    required += ("KITTY_CONFIG_DIRECTORY",)
if any(not os.environ.get(key) for key in required):
    sys.exit(0)
for entry in Path("/proc").iterdir():
    if not entry.name.isdecimal():
        continue
    fd = None
    try:
        fd = os.pidfd_open(int(entry.name))
        if (entry / "comm").read_text().strip() != name:
            continue
        environment = dict(item.split(b"=", 1) for item in (entry / "environ").read_bytes().split(b"\0") if b"=" in item)
        if all(environment.get(os.fsencode(key)) == os.fsencode(os.environ[key]) for key in required):
            signal.pidfd_send_signal(fd, getattr(signal, "SIG" + requested_signal))
    except (OSError, ValueError, ProcessLookupError):
        pass
    finally:
        if fd is not None:
            os.close(fd)
PYTHON
}

omarchy_process_record() {
  python3 - "$1" "$2" <<'PYTHON'
import json, os, select, sys, tempfile
pid = int(sys.argv[1])
fd = None
path = None
try:
    fd = os.pidfd_open(pid)
    with open(f"/proc/{pid}/stat") as source:
        raw = source.read()
    fields = raw[raw.rfind(")") + 1:].split()
    # Registration is only for the caller's own child. Refuse a PID that
    # vanished and was reused before Python opened it, including Python itself.
    if pid == os.getpid() or int(fields[1]) != os.getppid() or select.select([fd], [], [], 0)[0]:
        sys.exit(1)
    record = {"pid": pid, "startTime": fields[19]}
    output_fd, path = tempfile.mkstemp(dir=os.path.dirname(sys.argv[2]), prefix=".process-")
    with os.fdopen(output_fd, "w") as output:
        json.dump(record, output)
    os.replace(path, sys.argv[2])
except (OSError, ValueError, IndexError, AttributeError, OverflowError):
    sys.exit(1)
finally:
    if fd is not None:
        os.close(fd)
    if path is not None and os.path.exists(path):
        os.unlink(path)
PYTHON
}

omarchy_process_control() {
  python3 - "$1" "${2:-}" <<'PYTHON'
import json, os, select, signal, sys
fd = None
try:
    with open(sys.argv[1]) as source:
        record = json.load(source)
    pid = record["pid"]
    if not isinstance(pid, int) or pid <= 1:
        sys.exit(1)
    fd = os.pidfd_open(pid)
    with open(f"/proc/{pid}/stat") as source:
        raw = source.read()
    if raw[raw.rfind(")") + 1:].split()[19] != record["startTime"]:
        sys.exit(1)
    if select.select([fd], [], [], 0)[0]:
        sys.exit(1)
    if sys.argv[2]:
        signal.pidfd_send_signal(fd, getattr(signal, "SIG" + sys.argv[2]))
except (OSError, ValueError, KeyError, IndexError, AttributeError, TypeError, OverflowError):
    sys.exit(1)
finally:
    if fd is not None:
        os.close(fd)
PYTHON
}
