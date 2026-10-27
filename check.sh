#!/usr/bin/env bash
# Gramine-SGX readiness check: CPU -> BIOS -> kernel -> userspace -> real enclave run -> DCAP quote.
# Usage: ./check.sh [--no-run]   (--no-run skips building/launching the test enclave)
# Exit code = number of FAILs. Report is saved to results/<host>-sgx-<utc>.txt
set -u
. "$(dirname "$0")/lib.sh"
report sgx
env_info
[ -n "${KUBERNETES_SERVICE_HOST:-}" ] && info container kubernetes-pod
{ [ -f /.dockerenv ] || [ -f /run/.containerenv ]; } && info container docker/podman
gce=$(curl -fs -m 2 -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/machine-type 2>/dev/null)
[ -n "$gce" ] && info gce-machine-type "${gce##*/}"
az=$(curl -fs -m 2 -H Metadata:true "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text" 2>/dev/null)
[ -n "$az" ] && info azure-vm-size "$az"
{ flag tdx_guest || [ -e /dev/tdx_guest ]; } && info confidential-vm "Intel TDX guest (SGX is not available inside a TD)"

echo "== cpu"
declare -A C=()
PROBE_URL=https://github.com/tpluslabs/gramine-cheker/releases/download/latest/sgx-cpuid-linux-amd64
if has cc; then
    cc -O2 -o build/sgx-cpuid probe/sgx-cpuid.c 2>/dev/null
elif has curl; then  # prebuilt static binary from CI (.github/workflows/build.yml)
    curl -fsSL -m 30 -o build/sgx-cpuid "$PROBE_URL" && chmod +x build/sgx-cpuid
fi
if [ -x build/sgx-cpuid ]; then
    [ "$(id -u)" = 0 ] && modprobe msr 2>/dev/null
    while IFS='=' read -r k v; do C[$k]=$v; done < <(build/sgx-cpuid 2>/dev/null)
fi
if [ ${#C[@]} -eq 0 ]; then
    warn cpuid-probe "no probe (no cc, download failed); using /proc/cpuinfo (cannot tell CPU vs BIOS vs hypervisor)"
    flag sgx && C[sgx]=1 || C[sgx]=0
    flag sgx_lc && C[sgx_lc]=1 || C[sgx_lc]=0
    flag fsgsbase && C[fsgsbase]=1 || C[fsgsbase]=0
fi
[ "${C[hypervisor]:-0}" = 1 ] && info hypervisor "running under a hypervisor: SGX exists only if the VMM passes it through"
[ "${C[sgx]}" = 1 ] && pass cpuid.sgx || fail cpuid.sgx "CPU lacks SGX, or BIOS/hypervisor hides it"
[ "${C[sgx_lc]}" = 1 ] && pass cpuid.flc "Flexible Launch Control" || fail cpuid.flc "no FLC: unsupported by Gramine >= 1.9"
[ "${C[fsgsbase]}" = 1 ] && pass cpuid.fsgsbase || fail cpuid.fsgsbase
if [ -n "${C[sgx1]:-}" ]; then
    [ "${C[sgx1]}" = 1 ] && pass cpuid.sgx1 || fail cpuid.sgx1
    [ "${C[sgx2]}" = 1 ] && pass cpuid.sgx2 "EDMM possible" || warn cpuid.sgx2 "no SGX2/EDMM: keep sgx.edmm_enable=false"
    epc=${C[epc_bytes]}
    info epc "$((epc / 1048576)) MiB (enclave working set beyond this pages → slow)"
    [ "$epc" -gt 0 ] || fail epc "no EPC reported: PRMRR/EPC size 0 in BIOS?"
fi
if [ -n "${C[msr_sgx]:-}" ]; then
    [ "${C[msr_sgx]}" = 1 ] && pass bios.sgx-enabled "IA32_FEATURE_CONTROL[18]" || fail bios.sgx-enabled "SGX disabled in BIOS"
    [ "${C[msr_flc]}" = 1 ] && pass bios.flc-enabled "IA32_FEATURE_CONTROL[17]" || fail bios.flc-enabled "BIOS locked launch-enclave hash (set 'SGX Launch Control Policy: Unlocked')"
else
    info bios "MSR not readable (need root + msr module); relying on kernel flags"
fi

echo "== kernel"
kv=$(uname -r | cut -d- -f1)
[ "$(printf '%s\n5.11\n' "$kv" | sort -V | head -1)" = 5.11 ] && pass kernel.version ">= 5.11" || fail kernel.version "$kv < 5.11 (no in-kernel SGX driver)"
cfg=$( { zcat /proc/config.gz 2>/dev/null || cat "/boot/config-$(uname -r)" 2>/dev/null; } | grep '^CONFIG_X86_SGX=')
[ -n "$cfg" ] && pass kernel.config "$cfg" || info kernel.config "CONFIG_X86_SGX not found (config unavailable?)"
flag sgx && pass kernel.flag.sgx || fail kernel.flag.sgx "kernel did not enable SGX (BIOS/driver) — see dmesg"
flag sgx_lc && pass kernel.flag.sgx_lc || fail kernel.flag.sgx_lc
flag fsgsbase && pass kernel.flag.fsgsbase || fail kernel.flag.fsgsbase "needs kernel >= 5.9 and no 'nofsgsbase'"
if [ -e /dev/sgx_enclave ]; then
    pass dev.sgx_enclave "$(stat -c '%A %U:%G' /dev/sgx_enclave)"
    [ -r /dev/sgx_enclave ] && [ -w /dev/sgx_enclave ] || fail dev.sgx_enclave.rw "no rw access for $(id -un): add to its group"
    findmnt -no OPTIONS -T /dev/sgx_enclave | grep -qw noexec && fail dev.noexec "/dev mounted noexec: enclave mmap will fail"
else
    fail dev.sgx_enclave "missing: kernel has no EPC (see epc/dmesg); in a pod: needs sgx.intel.com/enclave"
fi
if [ -e /dev/sgx_provision ]; then
    g=$(stat -c %G /dev/sgx_provision)
    pass dev.sgx_provision "$(stat -c '%A %U:%G' /dev/sgx_provision)"
    id -nG aesmd 2>/dev/null | grep -qw "$g" && [ "$g" != root ] \
        || fail dev.sgx_provision.aesmd "aesmd not in group $g: QE3 won't load (0x4004); udevadm trigger --subsystem-match=misc, restart aesmd"
else
    warn dev.sgx_provision "missing: DCAP attestation will fail"
fi
tot=$(cat /sys/devices/system/node/node*/x86/sgx_total_bytes 2>/dev/null | awk '{s+=$1} END {print s+0}')
[ "$tot" -gt 0 ] && info kernel.epc "$((tot / 1048576)) MiB managed by kernel"
dmesg 2>/dev/null | grep -i sgx | head -5 | while read -r l; do info dmesg "$l"; done

echo "== userspace"
if [ -S /var/run/aesmd/aesm.socket ]; then pass aesmd "socket present"; else warn aesmd "no /var/run/aesmd/aesm.socket: quotes need aesmd"; fi
ldconfig -p 2>/dev/null | grep -q libdcap_quoteprov && pass dcap.qpl libdcap_quoteprov || warn dcap.qpl "libsgx-dcap-default-qpl missing"
for v in /sys/firmware/efi/efivars/SgxRegistration{ServerRequest,Status}-*; do [ -e "$v" ] && info uefi "${v##*/}"; done
[ -f /etc/sgx_default_qcnl.conf ] && info dcap.pccs "$(grep -m1 -o '"pccs_url"[^,]*' /etc/sgx_default_qcnl.conf)"
if has gramine-sgx; then
    pass gramine "$(gramine-manifest --version 2>/dev/null || echo installed)"
    has is-sgx-available && is-sgx-available 2>&1 | while read -r l; do info is-sgx-available "$l"; done
else
    fail gramine "not installed: run ./install.sh"
fi

if [ "${1:-}" != --no-run ] && has gramine-sgx && has make && has cc; then
    echo "== functional"
    [ -f ~/.config/gramine/enclave-key.pem ] || gramine-sgx-gen-private-key >/dev/null
    edmm=0; [ "${C[sgx2]:-0}" = 1 ] && edmm=1
    if make -s -C app clean all EDMM=$edmm >build/make.log 2>&1; then
        pass build "signed (edmm=$edmm)"
        ( cd app && timeout 60 gramine-direct hello 2>&1 ) | grep -q '^hello from enclave' \
            && pass run.gramine-direct || fail run.gramine-direct "libOS itself broken"
        r=$(cd app && timeout 120 gramine-sgx hello 2>&1); rc=$?
        printf '%s\n' "$r" | sed 's/^/      | /'
        grep -q '^hello from enclave' <<<"$r" && pass run.gramine-sgx "enclave launched" || fail run.gramine-sgx "rc=$rc"
        if grep -q '^quote_bytes=' <<<"$r"; then
            pass attest.dcap-quote "$(grep -o 'quote_bytes=.*' <<<"$r")"
        else
            fail attest.dcap-quote "check aesmd, dcap qpl, PCCS reachability, platform registration"
            j=$(journalctl -u aesmd --since "-3min" -o cat 2>/dev/null)
            grep -iE 'error|fail|No certificate' <<<"$j" | tail -5 | while read -r l; do info aesmd.log "$l"; done
            grep -q 'No certificate data' <<<"$j" \
                && info attest.hint "PCS has no PCK cert: platform not registered with Intel (README req. 15)"
        fi
    else
        fail build "see build/make.log"; tail -5 build/make.log
    fi
fi

summary Gramine-SGX
