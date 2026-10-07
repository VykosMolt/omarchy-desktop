#!/bin/bash

# Optional display-manager entry point. The maintained launcher owns all
# session behavior; this wrapper does not copy its implementation.
set -euo pipefail
launcher="$HOME/omarchy-arch-port/port/bin/omarchy-arch-session"
if [[ ! -x $launcher ]]; then
  echo "Omarchy session launcher not found: $launcher" >&2
  exit 1
fi
exec "$launcher" "$@"
