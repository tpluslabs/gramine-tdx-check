#!/usr/bin/env bash
# Builds Gramine-TDX (gramine-tdx + td-shim) into $GRAMINE_TDX_PREFIX (default /opt/gramine-tdx), installs QEMU,
# virtiofsd and the TD quote service (tdx-qgs). Run install.sh first (it adds the Intel SGX repo).
# Host kernel must already run with kvm_intel.tdx=1 (check-tdx.sh tells you).
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
P=${GRAMINE_TDX_PREFIX:-/opt/gramine-tdx}
GRAMINE_REV=8dc53f9a18625171e4a579f3b8c895a382c2d4d8
TDSHIM_REV=33fa83e4752b1d525ab0eb5ae84faad5dffc65ab
RUST=1.88.0
HERE=$(cd "$(dirname "$0")" && pwd)
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
export RUSTUP_HOME=$P/rust CARGO_HOME=$P/rust PATH=$P/rust/bin:$PATH

apt-get update
apt-get install -y qemu-system-x86 qemu-utils virtiofsd git build-essential clang llvm nasm pkg-config \
    libssl-dev curl wget autoconf bison gawk meson ninja-build python3-click python3-jinja2 \
    python3-pyelftools python3-voluptuous python3-tomli python3-tomli-w python3-cryptography \
    python3-protobuf python3-psutil libprotobuf-c-dev protobuf-c-compiler protobuf-compiler
apt-get install -y tdx-qgs || echo "WARN  tdx-qgs not installed (needs the Intel SGX repo from install.sh)"
modprobe vhost_vsock && echo vhost_vsock > /etc/modules-load.d/vhost_vsock.conf

mkdir -p "$P/src"
[ -x "$P/rust/bin/rustup" ] || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain $RUST
rustup target add --toolchain $RUST x86_64-unknown-none

S=$P/src/td-shim
[ -d "$S" ] || git clone https://github.com/confidential-containers/td-shim.git "$S"
git -C "$S" fetch origin refs/pull/846/head
git -C "$S" checkout -q $TDSHIM_REV
git -C "$S" submodule update --init --recursive
(cd "$S" && ./sh_script/preparation.sh && CC=clang AR=llvm-ar CC_x86_64_unknown_none=clang AR_x86_64_unknown_none=llvm-ar \
    cargo +$RUST build -p td-shim --target x86_64-unknown-none --release --features=main,tdx --no-default-features)

G=$P/src/gramine-tdx
[ -d "$G" ] || git clone -b intel_tdx https://github.com/gramineproject/gramine-tdx.git "$G"
git -C "$G" checkout -q -f $GRAMINE_REV
git -C "$G" apply "$HERE"/tdx/*.patch
cd "$G"
[ -d build ] || meson setup build --buildtype=debug --prefix="$P" \
    -Ddirect=enabled -Dsgx=enabled -Dvm=enabled -Dtdx=enabled -Dtdshim_path="$S"
guard() {
    for h in subprojects/glibc-*/glibc-*/sysdeps/unix/sysv/linux/sys/mount.h \
             build/subprojects/glibc-*/crt1.o.p/sysdeps/unix/sysv/linux/sys/mount.h; do
        [ -f "$h" ] && ! grep -q '#ifndef OPEN_TREE_CLONE' "$h" \
            && sed -i 's/^#define OPEN_TREE_CLONE[ \t].*/#ifndef OPEN_TREE_CLONE\n&\n#endif/' "$h"
    done
    return 0
}
guard
ninja -C build || { guard; ninja -C build; }
ninja -C build install
ln -sf "$(command -v qemu-system-x86_64)" "$P/bin/qemu"
ln -sf "$(ls /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd 2>/dev/null | head -1)" "$P/bin/virtiofsd"
# gramine-tdx's QEMU line talks to QGS over vsock 2:4050; tdx-qgs >= 1.27 defaults to a unix socket only.
[ -f /etc/qgs.conf ] && { grep -q '^port' /etc/qgs.conf || echo 'port = 4050' >> /etc/qgs.conf; }
systemctl enable qgsd 2>/dev/null && systemctl restart qgsd || true
echo "done. ./check-tdx.sh"
