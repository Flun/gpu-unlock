#!/usr/bin/env bash
# Verification script for VFI-unlocked CMP 170HX (80 GiB + PCIe Gen4 + P2P)
set -euo pipefail

echo "=== 1. Loaded Kernel Modules ==="
lsmod | grep -E "^(gpu_unlock|nvidia)" || echo "WARNING: gpu_unlock/nvidia not loaded"

echo ""
echo "=== 2. gpu_unlock Parameters ==="
if [[ -d /sys/module/gpu_unlock/parameters ]]; then
    for p in targets cmp80g cmp_sm126 cmp_pcie_gen hbm_governor; do
        [[ -f "/sys/module/gpu_unlock/parameters/$p" ]] && \
            printf "  %-16s = %s\n" "$p" "$(cat /sys/module/gpu_unlock/parameters/$p)"
    done
fi

echo ""
echo "=== 3. nvidia-smi Summary ==="
nvidia-smi --query-gpu=index,pci.bus_id,memory.total,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,clocks.mem,temperature.gpu,power.draw --format=csv

echo ""
echo "=== 4. PCIe Link & BAR1 Check ==="
for bdf in $(lspci -Dnn | awk '/10de:20c2/ {print $1}'); do
    echo "  [$bdf]"
    lspci -vv -s "$bdf" | grep -E "LnkCap:|LnkSta:|Region 1:|DevSta:" | sed 's/^/    /'
done

echo ""
echo "=== 5. Kernel Log Check (gpu_unlock / CMP Gen4 / Xid) ==="
dmesg | grep -iE "gpu_unlock:|CMP Gen4:|NVRM: Xid" | tail -n 30 || true
