#!/usr/bin/env bash
# Gramine-TDX readiness check (host side): BIOS -> kernel/KVM -> QEMU -> QGS -> app in a TD -> TD quote.
# Usage: ./check-tdx.sh [--no-run]   Exit code = number of FAILs. Report: results/<host>-tdx-<utc>.txt
# gramine-tdx is looked up in $GRAMINE_TDX_PREFIX (default /opt/gramine-tdx, see install-tdx.sh), then $PATH.
set -u
. "$(dirname "$0")/lib.sh"
report tdx
env_info
{ flag tdx_guest || [ -e /dev/tdx_guest ]; } && info confidential-vm "already inside a TD: run this on the host"

echo "== bios"
d=$(dmesg 2>/dev/null | grep 'virt/tdx')
grep -q 'BIOS enabled' <<<"$d" && pass bios.tdx "$(grep -o 'private KeyID range.*' <<<"$d")" \
    || fail bios.tdx "BIOS: enable TME, TME-MT, TDX, SEAM loader, TDX key split > 0"
flag sgx && pass bios.sgx "TD quotes need SGX (the TD quoting enclave)" || fail bios.sgx "SGX off: TDX attestation won't work"

echo "== kernel"
p=/sys/module/kvm_intel/parameters/tdx
if [ ! -e "$p" ]; then
    fail kvm.tdx "kvm_intel has no tdx parameter: kernel lacks TDX host support (upstream >= 6.16)"
elif [ "$(cat $p)" = Y ]; then
    pass kvm.tdx "kvm_intel.tdx=Y"
else
    fail kvm.tdx "off: add kvm_intel.tdx=1 to GRUB_CMDLINE_LINUX_DEFAULT, update-grub, reboot"
fi
grep -q 'module initialized' <<<"$d" && pass tdx.module || fail tdx.module "TDX module not initialized (see dmesg virt/tdx)"
while read -r l; do [ -n "$l" ] && info dmesg "$l"; done <<<"$d"
[ "$(id -u)" = 0 ] && modprobe vhost_vsock 2>/dev/null
for n in kvm vhost-vsock; do
    if [ -e /dev/$n ]; then
        [ -r /dev/$n ] && [ -w /dev/$n ] && pass dev.$n "$(stat -c '%A %U:%G' /dev/$n)" || fail dev.$n "no rw for $(id -un): add to group kvm"
    else
        fail dev.$n missing
    fi
done

echo "== userspace"
if has qemu-system-x86_64; then
    pass qemu "$(qemu-system-x86_64 --version | head -1)"
    qemu-system-x86_64 -object tdx-guest,help >/dev/null 2>&1 && pass qemu.tdx-guest || fail qemu.tdx-guest "QEMU built without TDX (needs >= 9.2)"
else
    fail qemu "qemu-system-x86_64 missing: run ./install-tdx.sh"
fi
vfs=$(ls /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd 2>/dev/null | head -1)
[ -n "$vfs" ] && pass virtiofsd "$vfs" || fail virtiofsd "missing: apt install virtiofsd"
if pidof qgs >/dev/null; then pass qgs "running"; else warn qgs "tdx-qgs not running: TD quotes will fail"; fi
[ -f /etc/qgs.conf ] && info qgs.conf "$(grep -v '^#' /etc/qgs.conf | xargs)"
grep -q '^port' /etc/qgs.conf 2>/dev/null || warn qgs.vsock "no 'port = 4050' in /etc/qgs.conf: QGS is unix-socket only, gramine-tdx expects vsock"
P=${GRAMINE_TDX_PREFIX:-/opt/gramine-tdx}
[ -d "$P/bin" ] && export PATH="$P/bin:$PATH" PYTHONPATH="$(ls -d "$P"/lib/python3*/site-packages 2>/dev/null | head -1)"
has gramine-tdx && pass gramine-tdx "$(command -v gramine-tdx)" || fail gramine-tdx "not found in $P/bin or PATH: run ./install-tdx.sh"

if [ "${1:-}" != --no-run ] && has gramine-tdx && has make && has cc; then
    echo "== functional"
    [ -f ~/.config/gramine/enclave-key.pem ] || gramine-sgx-gen-private-key >/dev/null
    rm -rf build/app-tdx && cp -r app build/app-tdx
    if make -s -C build/app-tdx clean all >build/make-tdx.log 2>&1; then
        pass build "manifest for $(command -v gramine-manifest)"
        r=$(cd build/app-tdx && timeout 120 gramine-tdx hello 2>&1); rc=$?
        printf '%s\n' "$r" | sed 's/^/      | /'
        grep -q 'hello from enclave' <<<"$r" && pass run.gramine-tdx "TD launched" || fail run.gramine-tdx "rc=$rc"
        grep -q 'quote_bytes=' <<<"$r" && pass attest.tdx-quote "$(grep -o 'quote_bytes=.*' <<<"$r")" \
            || fail attest.tdx-quote "check qgs (vsock 4050), dcap qpl/PCCS, platform registration"
    else
        fail build "see build/make-tdx.log"; tail -5 build/make-tdx.log
    fi
fi

summary Gramine-TDX
