# try1 - Hetzner DX154 (Dell PowerEdge R470), Ubuntu 26.04.1, kernel 7.0.0-38, BIOS untouched
## changes
- `./run.sh`: Gramine + Intel PSW from the fallback repos
- `/dev/sgx_provision` was `root:root 0600`: the `sgx_prv` group is created by the install after the node exists, so the udev rule never applied. Fixed with `udevadm trigger --subsystem-match=misc` + `systemctl restart aesmd` (before: aesmd `Failed to load QE3: 0x4004`, gramine `AESM error 38`)
- `/etc/sgx_default_qcnl.conf`: `pccs_url` → `https://api.trustedservices.intel.com/sgx/certification/v4/` (original in `.orig`)

## result
Hardware, BIOS, kernel: all PASS. 2017 MiB EPC, SGX2/EDMM, single socket.
Remaining FAILs are attestation only: `[QPL] No certificate data for this platform` (`0xe011`), gramine `AESM error 44`.
Intel PCS `GET /sgx/certification/v4/pckcert?encrypted_ppid=…` returns 404, so the platform isn't registered.
`PCKIDRetrievalTool` shows a platform manifest, so registration is needed even with one socket.

## next
Register the platform manifest with Intel (`POST https://api.trustedservices.intel.com/sgx/registration/v1/platform`,
body = PM from `/tmp/pckid_retrieval.csv` field 6, or install `sgx-ra-service`). Then rerun `./check.sh`.

# try2 - TDX host (`check-tdx.sh --no-run`)
## state found (set up by heytdep, not touched)
- `kvm_intel.tdx=1` in grub, TDX module initialized, KeyID range [32, 64), QEMU 10.2.1 with `tdx-guest`
- gramine-tdx built by hand and `helloworld` + a Rust HTTP server ran in a TD; the fixes are now in `install-tdx.sh` + `tdx/`
- `tdx-qgs` not installed, so no TD quotes yet

## result
All host checks PASS. Only FAIL: no `gramine-tdx` under `/opt/gramine-tdx` (`install-tdx.sh` not run yet).

## side effect
`PCKIDRetrievalTool` (run during try1 to get the encrypted PPID) set the `SgxRegistrationStatus` UEFI var to completed
(mtime 2026-10-27 13:21), so MPA won't auto-register this box. Manual registration works regardless.

# try3 - registered with Intel, full SGX + TDX runs
## changes
- Platform manifest POSTed to `https://api.trustedservices.intel.com/sgx/registration/v1/platform`: 201, PCK cert served right after
- `install-tdx.sh` run: gramine-tdx in `/opt/gramine-tdx`, `tdx-qgs` with `port = 4050` (1.27 defaults to unix socket only)
- New `tdx/gramine-tdx-getquote-shared-bit.patch`: the GetQuote GPA lacked the shared bit, KVM rejected it

## result
- **Gramine-SGX: READY.** Production enclave (`sgx.debug=false`, EDMM) runs, DCAP quote 4730 bytes.
- **Gramine-TDX: app runs in a TD; TD quote fails.** QGS gets the request and fetches the PCK cert (200), then
  `tee_att_get_quote return 0x11002` (`TEE_ATT_ERROR_INVALID_PARAMETER`). TDREPORT from the TD checks out: type `81000000`,
  TEE_TCB_INFO and TDINFO SHA-384 match the hashes in REPORTMACSTRUCT, report data ours. Cause still open: next step is a
  plain (non-Gramine) TD quote as baseline.

## BIOS (iDRAC Redfish, read-only), BIOS 1.9.16, microcode 0xA000151
`IntelSgx=On`, `PrmrrSize=2G`, `EnableTdx=Enabled`, `EnableTdxSeamldr=Enabled`, `KeySplit=1`, `MemoryEncryption=MultipleKeys`,
`SgxAutoRegistrationAgent=Disabled`, `SgxPackageInfoInBandAccess=Off`, `SgxLeWr=Enabled`, `SubNumaCluster=Disabled`, `NodeInterleave=Disabled`.
EPC can go up to 128 GB on this CPU: raise `PrmrrSize` if enclaves need more than 2 GB.
