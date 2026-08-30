#!/bin/bash

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d) || fail "test temp directory is available"
trap 'rm -rf "$test_tmp"' EXIT

fake_bin="$test_tmp/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/supergfxctl" <<'STUB'
#!/bin/bash

[[ $1 == "-s" ]] || exit 64

case "${BLOCKED:-no}" in
kill-only)
  trap '' TERM
  /usr/bin/sleep 30
  ;;
term)
  /usr/bin/sleep 30
  ;;
esac

((${FAIL_STATUS:-0})) && exit "$FAIL_STATUS"

printf '%s\n' "${SUPPORTED_MODES:-Integrated Hybrid}"
STUB

chmod +x "$fake_bin"/*

# The detector reads sysfs rather than lspci, so the GPU count is staged as
# device directories carrying a display class.
fake_pci="$test_tmp/pci"
stage_gpus() {
  rm -rf "$fake_pci"
  local i
  for ((i = 0; i < ${1:-1}; i++)); do
    mkdir -p "$fake_pci/0000:0$i:00.0"
    printf '0x030000\n' >"$fake_pci/0000:0$i:00.0/class"
  done
}
stage_gpus 1

hybrid_gpu() {
  OMARCHY_PCI_DEVICES_PATH="$fake_pci" PATH="$fake_bin:$ROOT/bin:$PATH" timeout --kill-after=1s 10s bash "$ROOT/bin/omarchy-hw-hybrid-gpu"
}

hybrid_gpu ||
  fail "hybrid GPU detection sees a supported Hybrid mode"
pass "hybrid GPU detection sees a supported Hybrid mode"

SUPPORTED_MODES="Integrated Vfio" hybrid_gpu
status=$?
((status == 1)) ||
  fail "hybrid GPU detection trusts supergfxctl when Hybrid is unsupported" "exit status: $status"
pass "hybrid GPU detection trusts supergfxctl when Hybrid is unsupported"

FAIL_STATUS=2 hybrid_gpu
status=$?
((status == 1)) ||
  fail "hybrid GPU detection hides on an ordinary supergfxctl failure" "exit status: $status"
pass "hybrid GPU detection hides on an ordinary supergfxctl failure"

BLOCKED=term hybrid_gpu
status=$?
((status == 1)) ||
  fail "hybrid GPU detection sees one GPU as non-hybrid after a clean timeout" "exit status: $status"
pass "hybrid GPU detection sees one GPU as non-hybrid after a clean timeout"

stage_gpus 2
BLOCKED=term hybrid_gpu ||
  fail "hybrid GPU detection counts multiple GPUs after a clean timeout"
pass "hybrid GPU detection counts multiple GPUs after a clean timeout"
stage_gpus 1

BLOCKED=kill-only hybrid_gpu
status=$?
((status != 124 && status != 137)) ||
  fail "hybrid GPU detection stays bounded when supergfxd ignores the timeout signal"
((status == 1)) ||
  fail "hybrid GPU detection sees one GPU as non-hybrid when supergfxd is wedged" "exit status: $status"
pass "hybrid GPU detection stays bounded when supergfxd ignores the timeout signal"

stage_gpus 2
BLOCKED=kill-only hybrid_gpu ||
  fail "hybrid GPU detection counts multiple GPUs when supergfxd is wedged"
pass "hybrid GPU detection counts multiple GPUs when supergfxd is wedged"

cat >"$fake_bin/omarchy-cmd-present" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$fake_bin/omarchy-cmd-present"

hybrid_gpu ||
  fail "hybrid GPU detection counts GPUs without supergfxctl"
pass "hybrid GPU detection counts GPUs without supergfxctl"
