#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# glvnd loads every installed EGL vendor to ask which claims the device, so a
# hybrid laptop's bar maps NVIDIA's EGL and GLX stacks before settling on Mesa
# and rendering on the integrated GPU regardless. That cost ~21MB resident and
# ~113MB RSS in a shell that never touches the discrete card.

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

stub_bin="$tmpdir/bin"
mkdir -p "$stub_bin"

# Record the environment quickshell is started with, then exit so the launcher's
# supervision loop sees a clean stop.
cat >"$stub_bin/systemd-cat" <<'STUB'
#!/bin/bash
{
  printf '%s\n' "__EGL_VENDOR_LIBRARY_FILENAMES=${__EGL_VENDOR_LIBRARY_FILENAMES-unset}"
  printf '%s\n' "__GLX_VENDOR_LIBRARY_NAME=${__GLX_VENDOR_LIBRARY_NAME-unset}"
} >"$OMARCHY_TEST_ENV_LOG"
exit 0
STUB
chmod +x "$stub_bin/systemd-cat"

printf '#!/bin/bash\nexit 0\n' >"$stub_bin/hyprctl"
chmod +x "$stub_bin/hyprctl"

vendor_json="$tmpdir/50_mesa.json"
printf '{}\n' >"$vendor_json"

run_launcher() {
  local drm=$1 vendor=$2 log="$tmpdir/env"
  : >"$log"
  OMARCHY_TEST_ENV_LOG="$log" \
  OMARCHY_DRM_CLASS_PATH="$drm" \
  OMARCHY_MESA_EGL_VENDOR="$vendor" \
  OMARCHY_PATH="$ROOT" \
  PATH="$stub_bin:$PATH" \
    timeout 20 "$ROOT/bin/omarchy-launch-shell" >/dev/null 2>&1 || true
  cat "$log"
}

# A machine with an Intel render node: pin the shell to Mesa.
intel_drm="$tmpdir/drm-intel"
mkdir -p "$intel_drm/renderD128/device"
printf '0x8086\n' >"$intel_drm/renderD128/device/vendor"
mkdir -p "$intel_drm/renderD129/device"
printf '0x10de\n' >"$intel_drm/renderD129/device/vendor"

output=$(run_launcher "$intel_drm" "$vendor_json")
grep -Fx "__EGL_VENDOR_LIBRARY_FILENAMES=$vendor_json" <<<"$output" >/dev/null ||
  fail "the shell is pinned to the Mesa EGL vendor when one can drive a render node" "$output"
grep -Fx "__GLX_VENDOR_LIBRARY_NAME=mesa" <<<"$output" >/dev/null ||
  fail "the shell is pinned to the Mesa GLX vendor alongside EGL" "$output"
pass "a Mesa-capable render node pins the shell to Mesa"

# An AMD render node counts the same way.
amd_drm="$tmpdir/drm-amd"
mkdir -p "$amd_drm/renderD128/device"
printf '0x1002\n' >"$amd_drm/renderD128/device/vendor"
output=$(run_launcher "$amd_drm" "$vendor_json")
grep -Fx "__GLX_VENDOR_LIBRARY_NAME=mesa" <<<"$output" >/dev/null ||
  fail "an AMD render node pins the shell to Mesa" "$output"
pass "an AMD render node pins the shell to Mesa"

# NVIDIA alone: pinning would leave the shell with no EGL at all.
nvidia_drm="$tmpdir/drm-nvidia"
mkdir -p "$nvidia_drm/renderD128/device"
printf '0x10de\n' >"$nvidia_drm/renderD128/device/vendor"
output=$(run_launcher "$nvidia_drm" "$vendor_json")
grep -Fx "__EGL_VENDOR_LIBRARY_FILENAMES=unset" <<<"$output" >/dev/null ||
  fail "a machine with only an NVIDIA render node is left alone" "$output"
pass "a machine with only an NVIDIA render node keeps every EGL vendor"

# No Mesa vendor file installed: nothing to pin to.
output=$(run_launcher "$intel_drm" "$tmpdir/absent.json")
grep -Fx "__EGL_VENDOR_LIBRARY_FILENAMES=unset" <<<"$output" >/dev/null ||
  fail "a missing Mesa vendor file pins nothing" "$output"
pass "a missing Mesa vendor file pins nothing"
