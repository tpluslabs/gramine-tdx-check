#!/usr/bin/env bash
# Shared by check.sh and check-tdx.sh: report file + PASS/FAIL/WARN/INFO helpers. Source, don't run.
# report <name>: tees all output to results/<host>-<name>-<utc>.txt
report() {
    cd "$(dirname "$0")" || exit
    mkdir -p results build
    OUT="results/$(hostname)-$1-$(date -u +%Y%m%dT%H%M%SZ).txt"
    exec > >(tee "$OUT") 2>&1
}
FAILS=0
pass() { printf 'PASS  %-22s %s\n' "$1" "${2:-}"; }
fail() { printf 'FAIL  %-22s %s\n' "$1" "${2:-}"; FAILS=$((FAILS + 1)); }
warn() { printf 'WARN  %-22s %s\n' "$1" "${2:-}"; }
info() { printf 'INFO  %-22s %s\n' "$1" "${2:-}"; }
has() { command -v "$1" >/dev/null 2>&1; }
flag() { grep -m1 '^flags' /proc/cpuinfo | grep -qw "$1"; }
env_info() {
    echo "== environment"
    . /etc/os-release 2>/dev/null
    info host "$(hostname)"
    info os "${PRETTY_NAME:-unknown}"
    info kernel "$(uname -r)"
    info cpu "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)"
    v=$(systemd-detect-virt 2>/dev/null); info virt "${v:-unknown}"
}
summary() {
    echo "== summary"
    [ $FAILS -eq 0 ] && echo "RESULT: READY for $1" || echo "RESULT: NOT READY for $1 ($FAILS failures)"
    echo "report: $OUT"
    exit $FAILS
}
