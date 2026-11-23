# gpu-unlock — VFI Hardware-Unlocked CMP 170HX (80 GiB + PCIe Gen4) Edition

> **Upstream Credit & Scope:** This is a specialized fork of [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) (`3.0.0-beta`), building on CMP 170HX unlock foundations from [cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) and [sayhellotojungle/cmpunlocker](https://github.com/sayhellotojungle/cmpunlocker). Original upstream documentation is preserved in [`docs/UPSTREAM_README.md`](docs/UPSTREAM_README.md) and all original licenses are retained in [`licenses/`](licenses/).

This fork is engineered specifically for **VFI (Voltage Fault Injection / Glitch) hardware-unlocked NVIDIA CMP 170HX** GPUs (80 GiB HBM2e, up to 128 SMs, PCIe Gen4, NVLink, 7/8-way MIG, 5× NVDEC/NVJPG/OFA) — and also supports mixed rigs with stock (non-VFI) CMP 170HX cards.

Validated across **13 VFI-unlocked CMP 170HX cards** (including dual-GPU Gen4 ×8 + native PCIe P2P + vLLM TP2 with zero Xid 79/62, **~1.96 TB/s** sustained HBM2e bandwidth, and **128 SM** full-silicon samples).

---

## Why This Fork Exists

Standard `gpu-unlock` / stock `nvidia-open` drivers frequently fail on VFI-unlocked 80 GiB + Gen4 CMP 170HX cards with **`Xid 79` (fell off the bus)**, **`Xid 62` (PMU halt)**, **`Gen15` (`0xffff`) link errors**, **`-EOPNOTSUPP`**, or falling back to **10 GiB VRAM**.

This repository fixes those failure modes end-to-end:

| Problem on VFI 80GB + Gen4 Cards | Fix in This Fork |
| :--- | :--- |
| **PCIe Gen4 retrain after RM/GSP init drops GPU (`Xid 79` / `Xid 119`)** | [`patches/nvidia-open-cmp170hx-gen4-pre-rm.patch`](patches/nvidia-open-cmp170hx-gen4-pre-rm.patch) moves `nv_cmp170hx_gen4_post()` **before** `rm_init_adapter()` with full `pci_save_state` / `pci_restore_state` protection. |
| **False `Gen15` (`LnkSta == 0xffff`) & destructive EQ retry (`lc3 \| 0x2`)** | Guards transient `0xffff` config reads, removes destructive `Perform Equalization` on Gen3→Gen4 retry, and skips retraining when the link is already at Gen4 (`16 GT/s`). |
| **Mixed VFI (80 GiB) + Stock (64 GiB) rigs fail with `-EOPNOTSUPP`** | [`kernel/gpu_unlock/unlock.c`](kernel/gpu_unlock/unlock.c) auto-detects per card via `LOCAL_MEMORY_RANGE` (`(native_lmr >> 7) & 3 == 1`): **80 GiB / 126+ SM** for VFI cards, **64 GiB / 70 SM** for stock cards. |
| **Driver loads before `gpu_unlock` → 10 GiB VRAM (`-EBUSY / -16`)** | Installer enforces `softdep nvidia pre: gpu_unlock` + rebuilds `initramfs`. |
| **Idle / P-state transitions trigger `Xid 62` (PMU halt)** | Defaults to `hbm_governor=0` for maximum multi-GPU stability (opt-in via `--hbm-governor 1`). |
| **Hard to set up from a clean OS (no NVIDIA driver installed)** | [`scripts/install-vfi-80g-gen4.sh`](scripts/install-vfi-80g-gen4.sh) installs prerequisites, stock NVIDIA open driver (if missing), patched `gpu_unlock` DKMS + firmware, patched `nvidia.ko`, and `modprobe`/`initramfs` in one command. |

---

## Verified Benchmark (VFI-Unlocked CMP 170HX 80 GiB, 128 SM Sample)

- **VRAM:** `81920 MiB` (80 GiB HBM2e, 10/12 FBP @ 1728 MHz, 76 GiB full alloc/R-W PASS)
- **HBM2e D2D Copy (4 GiB):** **`1952.4 GB/s`**
- **HBM2e Triad / Add:** **`1964.4 GB/s`**
- **PCIe Gen4 ×8 (Pinned H2D / D2H):** **`13.47 GB/s`** / **`13.22 GB/s`**
- **Multi-GPU:** Dual Gen4 ×8 + Native P2P + 64 GiB BAR1 per card, zero `Xid 79` / `Xid 62`

---

## Quick Start (Works Even on a Clean Ubuntu OS With No NVIDIA Driver)

> **Prerequisites:**
> - Your CMP 170HX card(s) must already be **hardware-unlocked via VFI** (80 GiB / PCIe Gen4 fuses burned) and cold-booted with the Pico disconnected. *(Stock non-VFI CMP 170HX cards also work and automatically fall back to 64 GiB / 70 SM.)*
> - Linux x86_64 (tested on Ubuntu 24.04 / kernel 6.8–7.0, NVIDIA Open Driver 570–610+).

### 1. Clone and Run the All-in-One Installer

```bash
git clone -b vfi-80g-gen4 https://github.com/Flun/gpu-unlock.git
cd gpu-unlock
sudo ./scripts/install-vfi-80g-gen4.sh
```

What the installer does automatically:
1. Installs build tools & kernel headers (`build-essential`, `dkms`, `linux-headers-$(uname -r)`, `patch`, etc.).
2. Detects all CMP 170HX (`10de:20c2`) PCIe BDFs via `lspci`.
3. If **no NVIDIA driver is installed**, installs the stock NVIDIA open driver (`nvidia-driver-580-open` / `570-open`).
4. Fetches/extracts `gpu-unlock` firmware assets and installs the patched `gpu_unlock` DKMS module.
5. Patches `open-gpu-kernel-modules` (`kernel-open/nvidia/nv.c`) with [`patches/nvidia-open-cmp170hx-gen4-pre-rm.patch`](patches/nvidia-open-cmp170hx-gen4-pre-rm.patch) and installs the resulting `nvidia*.ko` into `/lib/modules/$(uname -r)/updates/gpu-unlock-gen4/`.
6. Writes `/etc/modprobe.d/gpu-unlock-vfi80g.conf` (`softdep nvidia pre: gpu_unlock`, `cmp80g=1`, `cmp_sm126=1`, `hbm_governor=0`) and updates `initramfs`.

### 2. Reboot and Verify

```bash
sudo reboot
```

After reboot:

```bash
cd gpu-unlock
sudo ./scripts/verify-vfi-80g-gen4.sh
```

You should see:
- `gpu_unlock` and `nvidia` loaded cleanly
- `81920 MiB` total VRAM per VFI-unlocked card
- `pcie.link.gen.current = 4` (`16GT/s`) and `Region 1: ... [size=64G]`
- Zero `NVRM: Xid` errors in `dmesg`

### Installer Options

```bash
# Install patched gpu_unlock only (if you manage nvidia.ko separately):
sudo ./scripts/install-vfi-80g-gen4.sh --gpu-unlock-only

# Patch & build against a specific local open-gpu-kernel-modules directory:
sudo ./scripts/install-vfi-80g-gen4.sh --nvidia-src /path/to/open-gpu-kernel-modules

# Specify exact PCI BDFs manually (comma-separated):
sudo ./scripts/install-vfi-80g-gen4.sh --targets 0000:0a:00.0,0000:0b:00.0
```

---

## Motherboard BIOS & Kernel Parameters Checklist (Critical for Multi-GPU Gen4)

Many Gen4 link drops (`Xid 79`) and multi-GPU boot issues come from BIOS settings rather than the card:

1. **Above 4G Decoding:** `Enabled` (mandatory for 64 GiB BAR1 per card — 4 cards = 256 GiB MMIO)
2. **Resizable BAR:** `Enabled`
3. **PCIe Slot Link Speed (`PCIEX16_1/2 Mode`):** **`Auto`** *(Do **NOT** force `Gen4` in BIOS on AMD X570/AM4/AM5 boards — forcing Gen4 can break 16 GT/s EQ negotiation; leaving it on `Auto` lets the pre-RM Gen3→Gen4 step-up train cleanly!)*
4. **Spread Spectrum / Ten Bit Tag:** **`Auto`**
5. **Recommended GRUB kernel parameters (`/etc/default/grub`):**
   ```text
   GRUB_CMDLINE_LINUX_DEFAULT="quiet pcie_aspm=off iommu=pt"
   ```
   *(Run `sudo update-grub` and reboot after editing.)*

---

## Troubleshooting (`10 GiB` / `Xid 62` / `Xid 79`)

| Symptom | Cause | Fix |
| :--- | :--- | :--- |
| **`nvidia-smi` shows `10240 MiB` (10 GiB)** | `nvidia` bound the GPU before `gpu_unlock` ran (`gpu_unlock: unlock failed (-16)`). | Verify `/etc/modprobe.d/gpu-unlock-vfi80g.conf` contains `softdep nvidia pre: gpu_unlock` and run `sudo update-initramfs -u && sudo reboot`. |
| **`Xid 79` (GPU fell off the bus) during Gen4 load or boot** | Stock `nvidia.ko` retrained Gen4 after RM init, or BIOS forced Gen4/EQ. | Ensure patched `nvidia.ko` is active (`modinfo -n nvidia` should point to `updates/gpu-unlock-gen4/nvidia.ko`) and set BIOS PCIe Mode / Spread Spectrum to `Auto`. |
| **`Xid 62` (PMU has halted) on 2–4+ GPU rigs** | HBM idle governor (`hbm_governor=1`), aggressive undervolt/OC, 12V rail droop under multi-GPU transient spikes, or passive-cooling VRAM/VRM overheat. | Keep `hbm_governor=0`, enable persistence mode (`sudo nvidia-smi -pm 1`), verify active airflow over passive heatsinks, and test `sudo nvidia-smi -pl 180` to rule out PSU 12V droop. |

---

## 한국어 요약 (Korean Quick Guide)

- **대상:** 피코(VFI 글리치)로 하드웨어 풀언락한 **CMP 170HX 80 GiB + PCIe Gen4** 카드 전용 포크입니다. (순정 CMP 170HX와 혼용 시에도 카드별 80G/64G 자동 감지)
- **핵심 패치:**
  1. `nvidia.ko` (`nv.c`): Gen4 리트레인을 `rm_init_adapter()` 이전으로 이동, `Gen15(0xffff)` 가드, Gen3→Gen4 재시도 시 파괴적 EQ 비트 제거 (`Xid 79` 해결)
  2. `gpu_unlock` (`unlock.c`): 카드별 `LOCAL_MEMORY_RANGE` 기반 80 GiB / 64 GiB 자동 분기
  3. 드라이버가 전혀 없는 클린 우분투에서도 한 줄(`sudo ./scripts/install-vfi-80g-gen4.sh`)로 NVIDIA 오픈 드라이버 + `gpu_unlock` + 패치된 `nvidia.ko` 일괄 설치
- **주의:** 멀티 GPU(특히 X570 등)에서 BIOS의 `PCIEX16 Mode`와 `Spread Spectrum`은 `Gen4` 강제가 아니라 **`Auto`**로 두는 것이 가장 안정적입니다.
