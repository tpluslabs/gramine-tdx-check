# gramine-cheker

Finds hosts that can really run [Gramine](https://gramine.readthedocs.io) with Intel SGX (`gramine-sgx`),
from GKE pods and GCP VMs to bare metal in colocation. It checks the whole chain:
CPU → BIOS → hypervisor → kernel → userspace → enclave launch → DCAP quote.

```bash
git clone https://github.com/tpluslabs/gramine-cheker && cd gramine-cheker
sudo ./run.sh            # everything: install.sh + check.sh; on a TDX host also install-tdx.sh + check-tdx.sh

./check.sh --no-run      # fast, read-only: hardware/BIOS/kernel/userspace
sudo ./install.sh        # build tools + Gramine + aesmd + DCAP QPL (Ubuntu 22.04/24.04/26.04, Debian 12)
sudo ./check.sh          # full: builds the probe, then builds, signs and runs a real enclave and asks for a quote
./check-tdx.sh --no-run  # Gramine-TDX host: BIOS TDX, kvm_intel.tdx, TDX module, /dev/kvm, vhost-vsock, QEMU, QGS
sudo ./install-tdx.sh    # builds gramine-tdx + td-shim into /opt/gramine-tdx, installs QEMU, virtiofsd, tdx-qgs
sudo ./check-tdx.sh      # full: runs app/ inside a TD and asks for a TD quote
```

Run as root to get the BIOS checks (they read MSR `0x3a`). Each run saves a report to
`results/<host>-{sgx,tdx}-<utc>.txt`. The exit code is the number of FAILs; `0` means ready.
Kubernetes: `kubectl apply -f k8s/pod.yaml` (see the comments in the file).

| Path | What |
|---|---|
| `check.sh` | Gramine-SGX test runner |
| `check-tdx.sh` | Gramine-TDX (host side) test runner |
| `lib.sh` | report + PASS/FAIL helpers shared by both runners |
| `install-tdx.sh` | builds Gramine-TDX: upstream `gramine-tdx@intel_tdx` `8dc53f9a` + `tdx/*.patch`, td-shim `33fa83e` (PR #846, QEMU 9+ TempMem layout), Rust 1.88.0; guards glibc 2.39's `OPEN_TREE_CLONE` against Linux ≥ 6.x headers |
| `tdx/gramine-tdx-getquote-shared-bit.patch` | sets the TDX shared bit on the `GetQuote` TDVMCALL buffer GPA: KVM rejects a private GPA, so `/dev/attestation/quote` failed with EACCES before reaching QGS |
| `tdx/gramine-tdx-mmio-shared-bit.patch` | sets the TDX shared bit on MMIO `#VE` requests (without it virtio init fails under QEMU 10) and drops a conflicting `<string.h>` include |
| `probe/sgx-cpuid.c` | reads raw CPUID leaf 7/0x12 and `IA32_FEATURE_CONTROL`, so it can tell "CPU lacks SGX" apart from "BIOS disabled it". Built on the fly if `cc` exists, else downloaded prebuilt from the `latest` release |
| `.github/workflows/build.yml` | CI: lints the scripts and builds the probe as a static binary on every push/PR. Pushes to `main` update the rolling [`latest`](https://github.com/tpluslabs/gramine-cheker/releases/tag/latest) prerelease; `v*` tags get a versioned release. The binary ships with a `.sha256` |
| `app/` | minimal enclave: prints `hello from enclave`, then gets a DCAP quote via `/dev/attestation/quote` |
| `install.sh` | installs build tools and the runtime dependencies |
| `run.sh` | `install.sh` + `check.sh`, then the TDX pair when `kvm_intel.tdx=Y`, as root |
| `k8s/pod.yaml` | runs the check inside a pod |

---

## 1. What Gramine-SGX needs (all of it)

Gramine ≥ 1.9 supports **only** the upstream in-kernel driver, so **FLC is mandatory**.

| # | Layer | Requirement | Checked by |
|---|---|---|---|
| 1 | CPU | Intel CPU with SGX (`CPUID.7.0:EBX[2]`) | `cpuid.sgx` |
| 2 | CPU | Flexible Launch Control (`CPUID.7.0:ECX[30]`, `sgx_lc`) | `cpuid.flc` |
| 3 | CPU | FSGSBASE | `cpuid.fsgsbase` |
| 4 | CPU | SGX2/EDMM: optional, but needed for `sgx.edmm_enable=true` (dynamic memory, faster startup) | `cpuid.sgx2` |
| 5 | BIOS | SGX = **Enabled** (not "Software Controlled"), `IA32_FEATURE_CONTROL[18]` | `bios.sgx-enabled` |
| 6 | BIOS | SGX Launch Control Policy = **Unlocked** (`IA32_FEATURE_CONTROL[17]`) | `bios.flc-enabled` |
| 7 | BIOS | PRMRR/EPC size > 0; on Xeon Scalable, TME/TME-MT enabled (needed for SGX), and on multi-socket, UMA/NUMA settings as the board vendor requires | `epc` |
| 8 | Hypervisor | For VMs: the VMM has to expose SGX and an EPC section to the guest. **No public cloud except Azure DCsv3/DCdsv3 (retiring) and Alibaba g7t/c7t/r7t does this.** TDX guests can't use SGX | `cpuid.*`, `confidential-vm` |
| 9 | Kernel | Linux ≥ 5.11, `CONFIG_X86_SGX=y`, FSGSBASE enabled (≥ 5.9, no `nofsgsbase`) | `kernel.*` |
| 10 | Kernel | `/dev/sgx_enclave` (rw for the user), `/dev/sgx_provision` (for attestation), `/dev` **not** `noexec` | `dev.*` |
| 11 | Containers | Device nodes passed in (k8s: [Intel SGX device plugin](https://github.com/intel/intel-device-plugins-for-kubernetes), resources `sgx.intel.com/{epc,enclave,provision}`), aesmd socket reachable | `dev.*`, `aesmd` |
| 12 | Userspace | `gramine` package (`gramine-sgx`, `gramine-manifest`, `gramine-sgx-sign`, `is-sgx-available`), signing key from `gramine-sgx-gen-private-key` (RSA-3072) | `gramine`, `build` |
| 13 | Attestation | `sgx-aesm-service` + `libsgx-aesm-{quote-ex,ecdsa}-plugin` (aesmd running, `/var/run/aesmd/aesm.socket`) | `aesmd` |
| 14 | Attestation | `libsgx-dcap-default-qpl` + `/etc/sgx_default_qcnl.conf` pointing at a reachable PCCS (or at your provider's cache). EPID/IAS is dead (EOL April 2025), so it's DCAP only | `dcap.*` |
| 15 | Attestation | Platform registered with Intel PCS: PCS has a PCK cert for it. Multi-socket boxes need multi-package registration (`sgx-ra-service` / MPA). Single-socket Xeon 6 boxes need it too: the DX154 (6741P) has a platform manifest (`SgxRegistrationServerRequest` UEFI var) and PCS returns 404 for its PCK cert until it is registered. Don't run `PCKIDRetrievalTool` casually: it sets the `SgxRegistrationStatus` UEFI var to completed, after which MPA skips registration | `attest.dcap-quote`, `attest.hint`, `uefi` |
| 16 | Keep current | TCB: microcode/BIOS recovery. An out-of-date TCB still produces quotes, but verifiers will report `OUT_OF_DATE`/`SW_HARDENING_NEEDED` | manual |

The only full proof is the end-to-end test: `run.gramine-sgx` (enclave launched in production mode, `sgx.debug=false`)
plus `attest.dcap-quote`.

---

## 2. CPUs that can run Gramine-SGX

"Capable" here means SGX **with FLC**. Always check the exact SKU on [ark.intel.com](https://ark.intel.com)
("Intel SGX" and "Max Enclave Size") and confirm it with `check.sh`.

### ✅ Usable

| Family | Codename | SGX2/EDMM | EPC (per socket) | Notes |
|---|---|---|---|---|
| Xeon E-2100 (E-21xx) | Coffee Lake | no | 128 MB (~93 MB usable) | single socket |
| Xeon E-2200 (E-22xx) | Coffee Lake-R | no | 128 MB | single socket |
| Xeon E-2300 (E-23xx) | Rocket Lake | script reports it | up to 512 MB | single socket |
| Xeon D-1700 / D-2700 | Ice Lake-D | yes | per SKU | edge/embedded |
| Xeon Scalable 3rd gen (x3xx, **not** Cooper Lake x3xxH) | Ice Lake-SP | yes | 8–512 GB, per SKU | first server line with big EPC |
| Xeon Scalable 4th gen (x4xx) | Sapphire Rapids | yes | up to 512 GB, per SKU | also has TDX |
| Xeon Scalable 5th gen (x5xx) | Emerald Rapids | yes | up to 512 GB, per SKU | also has TDX |
| Xeon 6 P-core (6500P/6700P/6900P) | Granite Rapids | yes | per SKU | also has TDX |
| Xeon 6+ E-core (69xxE+) | Clearwater Forest | per SKU | per SKU | 2026; SGX + TDX on all models |
| Xeon 7 | Diamond Rapids | tbd | tbd | due 2027; Intel lists SGX + TDX |
| Pentium/Celeron J/N 4xxx/5xxx | Gemini Lake | yes | 128 MB | lab/dev only |

Verify on ARK before buying: Xeon E-2400 (Raptor Lake-E), Xeon W-3300, Xeon 6 E-core (Sierra Forest).

SGX isn't being phased out on servers; only client (Core) chips dropped it. New Xeons ship SGX and TDX side by side, and
TDX attestation itself needs SGX enabled (its quoting enclave is an SGX enclave). So on bare metal you can run Gramine-SGX
enclaves and TDX VMs on the same box. Only *inside* a TDX VM is SGX unavailable.

---

Public clouds with real SGX: Azure DCsv3/DCdsv3 (closing, see [Azure](#azure)) and Alibaba g7t/c7t/r7t.

---

## 4. OVHcloud bare metal

Source: OVH public order catalog API (`/1.0/order/catalog/public/{baremetalServers,eco}?ovhSubsidiary=FR`), pulled 2026-09-29.
Availability differs by region/subsidiary.

How to enable SGX: Control Panel → server → *Intel SGX*, or the API:
`GET /dedicated/server/{serviceName}/biosSettings/sgx`, then
`POST /dedicated/server/{serviceName}/biosSettings/sgx/configure` (reboots the server; follow the task with
`GET /dedicated/server/{serviceName}/task/{taskId}`). A 404 on the GET means OVH offers no SGX toggle for that server.
Before ordering many, check that the toggle exists on one, especially on the Eco (Kimsufi/So you Start/Rise) lines
where you have no BIOS access.

### ✅ CPU capable (SGX + FLC)

| Range | Plan | CPU | 
|---|---|---|
| Rise | RISE-1 | Xeon E-2386G |
| Rise | RISE-2 | Xeon E-2388G |
| Rise | RISE-6 | Xeon Gold 6312U (Ice Lake) |
| So you Start | SYS-1 | Xeon E-2136 |
| So you Start | SYS-3 | Xeon E-2288G |
| Kimsufi | KS-5-A | Xeon E-2274G |
| Scale | Scale-i1 | Xeon Gold 6426Y (SPR) / Xeon 6517P |
| Scale | Scale-i2 | Xeon Gold 6442Y (SPR) / Xeon 6527P |
| Scale | Scale-i3 | Xeon Gold 6438M (SPR) / Xeon 6737P |
| High Grade | HGR-HCI-i1 | 2× Xeon Gold 5515+ (EMR) / 2× Xeon 6517P |
| High Grade | HGR-HCI-i2 | 2× Xeon Gold 6526Y (EMR) / 2× Xeon 6527P |
| High Grade | HGR-HCI-i3 | 2× Xeon Gold 6542Y (EMR) |
| High Grade | HGR-HCI-i4 | 2× Xeon Gold 6554S (EMR) |
| High Grade | HGR-SDS-1 | 2× Xeon Gold 5515+ (EMR) |
| High Grade | HGR-SDS-2 | 2× Xeon Gold 6542Y (EMR) |
| High Grade | HGR-STOR-1 | Xeon Gold 6554S (EMR) |

Dual-socket HGR boxes need multi-package platform registration before DCAP quotes work (requirement 15).
The E-2xxx boxes have a small EPC (128/512 MB), which is fine for small enclaves.

## Hetzner bare metal

Source: Intel ARK and Hetzner product pages, checked 2026-10-06. DX154 tested 2026-10-27: see `results/hetzner-DX154-Xeon-6741P-26.04.md`.

| Plan | CPU | Max EPC per CPU | Notes |
|---|---|---|---|
| DX154 | Xeon 6741P (Granite Rapids) | 128 GB | **tested, Gramine-SGX READY** after manual platform registration: SGX2, 2 GB EPC as delivered (`PrmrrSize=2G`, iDRAC), DCAP quote OK. TDX on in BIOS; Gramine-TDX runs apps, TD quote still fails (see results) |
| EX131 | Xeon 6731P (Granite Rapids) | 128 GB | CPU capable; Hetzner says nothing about SGX in BIOS |
| DX294 | 2× Xeon 6787P (Granite Rapids) | 512 GB | dual socket, so needs multi-package registration (requirement 15) |

Hetzner has no SGX toggle. Before ordering, ask support whether SGX is enabled in BIOS (or for KVM/BIOS access) and
whether all memory channels are populated symmetrically. A box can report SGX on and still have zero EPC: the OVH
Scale-i1 (Xeon 6517P) does. So run `check.sh` on one box first.


---

## 5. Reading results

| First FAIL | Meaning / fix |
|---|---|
| `cpuid.sgx` with `hypervisor` INFO | VM/pod: the provider doesn't expose SGX, so move to bare metal |
| `cpuid.sgx` on bare metal | CPU without SGX, or SGX set to Disabled in BIOS |
| `cpuid.flc` / `bios.flc-enabled` | old CPU, or BIOS "Launch Control Policy" locked, so set it to Unlocked |
| `bios.sgx-enabled`, `epc` | BIOS: SGX Enabled, PRMRR size > 0, TME on (Xeon SP) |
| `kernel.*` | kernel < 5.11, or `dmesg \| grep sgx` shows why the driver didn't load |
| `dev.*` | udev/group permissions, or the container didn't get the devices |
| `run.gramine-sgx` | see the enclave log printed above it; often EPC too small or `noexec` |
| `run.gramine-sgx` with `AESM error 38`, `dev.sgx_provision.aesmd` | aesmd can't open `/dev/sgx_provision` (QE3 0x4004): `udevadm trigger --subsystem-match=misc`, restart aesmd |
| `run.gramine-sgx` with `AESM error 44`, `attest.hint` | PCS has no PCK cert (`0xe011`): register the platform (req. 15) |
| `attest.dcap-quote` | aesmd not running, QPL/PCCS misconfigured, platform not registered |
| `bios.tdx` | BIOS: TME, TME-MT, TDX, SEAM loader, TDX key split > 0 |
| `kvm.tdx`, `tdx.module` | kernel without TDX host support, or `kvm_intel.tdx=1` missing from the cmdline |
| `run.gramine-tdx` | see the TD console printed above it |
| `attest.tdx-quote` | `tdx-qgs` not running (QEMU talks to it on vsock 4050), or the same PCCS/registration causes as SGX |

## Google Cloud (GCE / GKE)

**Verdict: nothing on GCP runs Gramine-SGX.** Google exposes SGX on no machine type, bare metal included.
Intel confidential computing on GCP means **TDX** (Confidential VM / Confidential GKE Nodes on C3), and SGX
can't be used from inside a TD.

## Azure

**Verdict: only DCsv3/DCdsv3 run Gramine-SGX, and they are being retired.** From **2026-11-01** no new subscriptions get them
(capacity-restricted), and they stop working on **2029-10-31**. Microsoft names no SGX successor: its migration guide points to
TDX (DCesv6/DCedsv6) VMs or to Confidential Container Instances. The v6 series runs on Emerald
Rapids, which has SGX in silicon, but inside a TDX VM the guest never sees it. Either get a DCsv3 subscription before
2026-11-01, or plan on bare metal.

Naming: `e` = Intel TDX, no letter = Intel SGX, `d` = local temp disk, `s` = premium storage.

| Series | CPU | Isolation | Gramine-SGX | vCPU | RAM (4 GiB/vCPU¹) | Local temp disk | Max data disks | Network (Mbps) | Accel. net | Ephemeral OS | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **DCsv3** | Intel Xeon Ice Lake, 3.5 GHz turbo | **SGX enclaves** + TME-MK; **EPC 4–256 GiB** (½ of RAM up to DC16, then 128/192/256) | ✅ | 1–48 **physical cores**¹ | 8–384 | none | 4–32 | not published | no | yes | GA; closed to new subs 2026-11-01; retires 2029-10-31 |
| **DCdsv3** | same | same | ✅ | 1–48 cores¹ | 8–384 | 75–2,400 GiB | 4–32 | not published | **yes** | no | same as DCsv3 |
| DCesv6 | Intel Xeon Platinum 8573C (Emerald Rapids), 3.0 GHz all-core, AMX | TDX CVM | ❌ (TDX only, `gramine-tdx` experimental) | 2–128 | 8–512 | none | 8–64 (Premium v2, Ultra) | 12,500–54,000 | no (MANA) | no | GA |
| DCedsv6 | same | TDX CVM | ❌ | 2–128 | 8–512 | 110–7,040 GiB (up to 6 disks) | 8–64 | 7,000–40,000 | no | no | GA |

¹ On DCsv3/DCdsv3 each unit is a physical core with no hyperthreading, and RAM is 8 GiB per core. DCesv6/DCedsv6 have
4 GiB per vCPU.

Common to all four: Gen2 VMs only, no live migration, no memory-preserving updates, no nested virtualization. DCesv6/DCedsv6 support confidential OS disk
encryption with a customer- or platform-managed key (Key Vault / Managed HSM).

The practical differences:
- **Which kind of isolation.** DCsv3/DCdsv3 protect individual *processes* (SGX enclaves), which is what Gramine-SGX needs.
  DCesv6/DCedsv6 protect the *whole VM* (TDX) and runs unmodified apps, no Gramine needed. The attestation is
  then about the VM, so the trusted base includes the guest kernel.
- **Attestation.** On DCsv3, DCAP quotes come through the Azure DCAP client / THIM cache, so no PCCS of your own. You may still
  need to point `/etc/sgx_default_qcnl.conf` (or `az-dcap-client`) at it, and `check.sh` validates that. TDX VMs attest through vTPM +
  Microsoft Azure Attestation or Intel Trust Authority.
- **v3 → v6.** Newer CPU (AMX), up to 128 vCPUs / 512 GiB, twice the data disks, Premium SSD v2 / Ultra, published network
  bandwidth up to 54 Gbps.

Sources: Microsoft Learn size pages for each series (retrieved 2026-09-29) and the
[DCsv3/DCdsv3 retirement guide](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/retirement/dcsv3-series-retirement).
