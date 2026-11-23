#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# All-in-one installer for VFI (glitch) hardware-unlocked CMP 170HX (80 GiB + PCIe Gen4)
# Supports clean Ubuntu/Debian systems (even with no NVIDIA driver installed yet).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="$REPO_ROOT/patches/nvidia-open-cmp170hx-gen4-pre-rm.patch"
KVER="$(uname -r)"
GPU_UNLOCK_ONLY=0
NVIDIA_SRC=""
NVIDIA_VER=""
TARGETS=""
HBM_GOVERNOR=0
SKIP_APT=0

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Options:
  --targets BDF1,BDF2     Comma-separated PCI BDFs (default: auto-detect all 10de:20c2)
  --gpu-unlock-only       Install patched gpu-unlock DKMS + firmware + modprobe only (skip nvidia.ko Gen4 patch)
  --nvidia-src DIR        Path to existing open-gpu-kernel-modules source tree to patch & build
  --nvidia-ver VER        Download & build NVIDIA/open-gpu-kernel-modules tag VER (default: match installed driver)
  --hbm-governor 0|1      Enable HBM idle governor (default: 0 for maximum stability / zero Xid 62)
  --skip-apt              Skip apt package prerequisite installation
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --targets) TARGETS="$2"; shift 2 ;;
        --gpu-unlock-only) GPU_UNLOCK_ONLY=1; shift ;;
        --nvidia-src) NVIDIA_SRC="$2"; shift 2 ;;
        --nvidia-ver) NVIDIA_VER="$2"; shift 2 ;;
        --hbm-governor) HBM_GOVERNOR="$2"; shift 2 ;;
        --skip-apt) SKIP_APT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo $0 ...)"
    exit 1
fi

echo "================================================================"
echo " gpu-unlock (VFI 80GB + Gen4 Edition) Installer"
echo " Kernel: $KVER"
echo "================================================================"

# 1. Prerequisites
if [[ $SKIP_APT -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
    echo "[1/6] Installing build prerequisites..."
    apt-get update -qq
    apt-get install -y -qq build-essential dkms "linux-headers-$KVER" python3 curl git zstd pciutils patch
else
    echo "[1/6] Skipping apt prerequisites."
fi

# 2. Auto-detect CMP 170HX GPUs
if [[ -z "$TARGETS" ]]; then
    TARGETS="$(lspci -Dnn | awk '/10de:20c2/ {print $1}' | paste -sd, -)"
fi
if [[ -z "$TARGETS" ]]; then
    echo "WARNING: No CMP 170HX (10de:20c2) detected via lspci."
    echo "         Re-run with --targets 0000:xx:00.0 if installing offline."
else
    echo "[2/6] Detected CMP 170HX target(s): $TARGETS"
fi

# 3. Check NVIDIA driver userspace
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo ""
    echo "[!] No NVIDIA driver detected on this machine."
    if command -v apt-get >/dev/null 2>&1; then
        echo "    Installing stock NVIDIA open driver via apt (recommended for clean OS)..."
        echo "    You can also install any NVIDIA >=570 open driver (.run or apt) and re-run this script."
        if apt-cache show nvidia-driver-580-open >/dev/null 2>&1; then
            apt-get install -y nvidia-driver-580-open
        elif apt-cache show nvidia-driver-570-open >/dev/null 2>&1; then
            apt-get install -y nvidia-driver-570-open
        else
            echo "ERROR: Could not find nvidia-driver-580-open / 570-open in apt."
            echo "       Please install an NVIDIA Open GPU driver first (e.g. via NVIDIA CUDA repo or .run --kernel-module-type=open), then re-run."
            exit 1
        fi
    else
        echo "ERROR: Please install an NVIDIA Open GPU driver first, then re-run."
        exit 1
    fi
fi

# 4. Build firmware assets & install gpu-unlock DKMS
echo "[3/6] Fetching/building gpu-unlock firmware assets & installing DKMS..."
cd "$REPO_ROOT"
make assets
make install

# 5. Patch & build open-gpu-kernel-modules (nvidia.ko pre-RM Gen4 retrain fix)
if [[ $GPU_UNLOCK_ONLY -eq 0 ]]; then
    echo "[4/6] Building patched nvidia.ko (Pre-RM Gen4 retrain + Gen15 guard)..."
    if [[ -z "$NVIDIA_SRC" ]]; then
        if [[ -z "$NVIDIA_VER" ]]; then
            # Detect installed driver version from modinfo or nvidia-smi
            NVIDIA_VER="$(modinfo -F version nvidia 2>/dev/null || true)"
            if [[ -z "$NVIDIA_VER" ]]; then
                NVIDIA_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
            fi
        fi
        if [[ -z "$NVIDIA_VER" ]]; then
            echo "ERROR: Could not detect installed NVIDIA driver version. Pass --nvidia-ver <VER> or --nvidia-src <DIR>."
            exit 1
        fi
        echo "  Detected NVIDIA driver version: $NVIDIA_VER"
        # Check if DKMS already unpacked nvidia open sources locally
        LOCAL_DKMS_SRC="/usr/src/nvidia-$NVIDIA_VER"
        BUILD_DIR="/tmp/nvidia-open-gen4-$NVIDIA_VER"
        rm -rf "$BUILD_DIR"
        if [[ -f "$LOCAL_DKMS_SRC/nvidia/nv.c" ]]; then
            echo "  Copying local DKMS source from $LOCAL_DKMS_SRC..."
            mkdir -p "$BUILD_DIR/kernel-open"
            cp -a "$LOCAL_DKMS_SRC/." "$BUILD_DIR/kernel-open/"
            NVIDIA_SRC="$BUILD_DIR"
        else
            echo "  Downloading NVIDIA/open-gpu-kernel-modules tag $NVIDIA_VER from GitHub..."
            git clone --depth 1 --branch "$NVIDIA_VER" https://github.com/NVIDIA/open-gpu-kernel-modules.git "$BUILD_DIR"
            NVIDIA_SRC="$BUILD_DIR"
        fi
    fi

    cd "$NVIDIA_SRC"
    if grep -q "nv_cmp170hx_gen4_post" kernel-open/nvidia/nv.c; then
        echo "  Patch already present in $NVIDIA_SRC/kernel-open/nvidia/nv.c"
    else
        echo "  Applying $PATCH_FILE..."
        patch -p1 --fuzz=3 < "$PATCH_FILE"
    fi

    echo "  Compiling nvidia.ko for kernel $KVER..."
    if [[ -f "$NVIDIA_SRC/Makefile" ]] && grep -q "modules" "$NVIDIA_SRC/Makefile"; then
        make -j"$(nproc)" KERNEL_UNAME="$KVER" modules
        KO_DIR="$NVIDIA_SRC/kernel-open"
    else
        make -C "$NVIDIA_SRC/kernel-open" -j"$(nproc)" SYSSRC="/lib/modules/$KVER/build" modules
        KO_DIR="$NVIDIA_SRC/kernel-open"
    fi

    DEST_DIR="/lib/modules/$KVER/updates/gpu-unlock-gen4"
    mkdir -p "$DEST_DIR"
    for ko in nvidia.ko nvidia-uvm.ko nvidia-modeset.ko nvidia-drm.ko nvidia-peermem.ko; do
        if [[ -f "$KO_DIR/$ko" ]]; then
            install -Dm644 "$KO_DIR/$ko" "$DEST_DIR/$ko"
        fi
    done
    echo "  Installed patched NVIDIA open modules to $DEST_DIR"
else
    echo "[4/6] Skipping nvidia.ko patch (--gpu-unlock-only)."
fi

# 6. Configure modprobe load order & options + update initramfs
echo "[5/6] Writing /etc/modprobe.d/gpu-unlock-vfi80g.conf..."
cat <<EOF > /etc/modprobe.d/gpu-unlock-vfi80g.conf
# Generated by Flun/gpu-unlock (VFI 80GB + Gen4 Edition)
# Ensure gpu_unlock ALWAYS initializes before nvidia binds the PCI device.
softdep nvidia pre: gpu_unlock
options gpu_unlock targets=$TARGETS cmp80g=1 cmp_sm126=1 cmp_pcie_gen=2 cmp_pcie_e1=1 hbm_governor=$HBM_GOVERNOR
EOF

# Remove any temporary VFI blacklist if present
rm -f /etc/modprobe.d/blacklist-nvidia-vfi.conf

echo "[6/6] Running depmod and updating initramfs..."
depmod -a "$KVER"
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k "$KVER"
elif command -v dracut >/dev/null 2>&1; then
    dracut --force --kver "$KVER"
elif command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P
fi

echo ""
echo "================================================================"
echo " Installation complete! Please reboot now."
echo " After reboot, run: sudo $REPO_ROOT/scripts/verify-vfi-80g-gen4.sh"
echo "================================================================"
