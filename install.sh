#!/usr/bin/env bash
# Installs build tools + Gramine + Intel SGX PSW (aesmd) + DCAP quote provider. Ubuntu 22.04/24.04/26.04, Debian 12.
set -euo pipefail
. /etc/os-release
SUDO=$([ "$(id -u)" = 0 ] || echo sudo)
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
# Neither repo covers every release (Gramine: none for 26.04; Intel: Ubuntu only): fall back to the newest older one.
FB=noble; [ "$ID" = debian ] && FB=jammy
cn() { curl -fsIo /dev/null -m 15 "$1/dists/$VERSION_CODENAME/Release" && echo "$VERSION_CODENAME" || echo $FB; }

$SUDO apt-get update
$SUDO apt-get install -y curl ca-certificates build-essential make git
GCN=$(cn https://packages.gramineproject.io)
ICN=$(cn https://download.01.org/intel-sgx/sgx_repo/ubuntu)
$SUDO curl -fsSLo "/usr/share/keyrings/gramine-keyring-$GCN.gpg" "https://packages.gramineproject.io/gramine-keyring-$GCN.gpg"
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/gramine-keyring-$GCN.gpg] https://packages.gramineproject.io/ $GCN main" \
    | $SUDO tee /etc/apt/sources.list.d/gramine.list
$SUDO curl -fsSLo /usr/share/keyrings/intel-sgx-deb.asc https://download.01.org/intel-sgx/sgx_repo/ubuntu/intel-sgx-deb.key
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-sgx-deb.asc] https://download.01.org/intel-sgx/sgx_repo/ubuntu $ICN main" \
    | $SUDO tee /etc/apt/sources.list.d/intel-sgx.list
$SUDO apt-get update
$SUDO apt-get install -y gramine sgx-aesm-service libsgx-aesm-quote-ex-plugin \
    libsgx-aesm-ecdsa-plugin libsgx-dcap-default-qpl
# Dropped by Intel after PSW 2.27 (FLC needs no launch enclave): still in the 22.04/24.04 repos, absent from 26.04.
$SUDO apt-get install -y libsgx-aesm-launch-plugin || echo "libsgx-aesm-launch-plugin not available: skipped (optional)"

for g in sgx sgx_prv; do getent group $g >/dev/null && $SUDO usermod -aG $g "$(id -un)"; done
# sgx_prv is created by the packages above, after /dev/sgx_provision exists: re-apply udev, else aesmd can't load QE3.
$SUDO udevadm trigger --subsystem-match=misc 2>/dev/null && $SUDO udevadm settle 2>/dev/null || true
# No local PCCS by default: talk to Intel PCS directly. Override with PCCS_URL=...
PCCS_URL=${PCCS_URL:-https://api.trustedservices.intel.com/sgx/certification/v4/}
$SUDO sed -i "s#\"pccs_url\": \"https://localhost:8081/sgx/certification/v4/\"#\"pccs_url\": \"$PCCS_URL\"#" /etc/sgx_default_qcnl.conf
pidof systemd >/dev/null && $SUDO systemctl restart aesmd 2>/dev/null || true

# Containers usually have no systemd: start aesmd by hand.
if ! pidof aesm_service >/dev/null; then
    $SUDO mkdir -p /var/run/aesmd
    $SUDO env LD_LIBRARY_PATH=/opt/intel/sgx-aesm-service/aesm /opt/intel/sgx-aesm-service/aesm/aesm_service || true
fi
echo "done. pccs_url in /etc/sgx_default_qcnl.conf: $PCCS_URL. Re-login for group changes, then ./check.sh"
