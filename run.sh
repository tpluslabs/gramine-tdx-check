#!/usr/bin/env bash
# One shot: install.sh + check.sh (Gramine-SGX); on a TDX host (kvm_intel.tdx=Y) also install-tdx.sh + check-tdx.sh.
# Usage: ./run.sh [--no-run]   Exit code = number of FAILs across both.
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
cd "$(dirname "$0")" || exit
./install.sh || echo "WARN  install.sh failed: checking with what is installed"
./check.sh "$@"; f=$?
if [ "$(cat /sys/module/kvm_intel/parameters/tdx 2>/dev/null)" = Y ]; then
    ./install-tdx.sh || echo "WARN  install-tdx.sh failed: checking with what is installed"
    ./check-tdx.sh "$@"; f=$((f + $?))
fi
exit $f
