#!/usr/bin/env bash
# Boot a croi EFI system partition under QEMU with edk2 firmware.
#
#   qemu.sh [--test <text>] [--exits] [--screendump <file.ppm>] [--registers-on <text>] [--iommu intel|amd] <amd64|arm64|rv64> <esp-dir> <work-dir> <edk2-dir> [qemu args...]
#
# The ESP directory is served as a virtual FAT drive. Writable firmware
# variable stores are copied into <work-dir> on first use. With --test the
# run is headless and console output is copied to stdout; it succeeds as
# soon as a line containing <text> appears and fails after a timeout. With
# --exits (test mode only) the run goes on after that line until QEMU exits
# by itself (a guest power-off, or a reset: test runs pass -no-reboot), and
# fails if it doesn't within the timeout. With
# --screendump (test mode only) the display is saved as a PPM at that point.
# With --registers-on (test mode only), the first line containing that text
# prints every CPU's PC and frame-pointer backtrace (qemu-monitor.py): where
# each CPU is when a lockup is reported. Alternatives are separated by '|'.
# --iommu picks amd64's IOMMU (default intel; QEMU takes one at a time),
# or on rv64 `base` for an IOMMU without MSI_FLAT. --aia (rv64): the APLIC and
# IMSICs instead of the PLIC (K12i).

set -euo pipefail

expect=
exits=
screendump=
registers_on=
iommu=intel
aia=
while [[ ${1:-} == --* ]]; do
  case $1 in
    --test) expect=${2:?--test needs the text to wait for}; shift 2 ;;
    --exits) exits=1; shift ;;
    --screendump) screendump=${2:?--screendump needs a file}; shift 2 ;;
    --registers-on) registers_on=${2:?--registers-on needs the text to wait for}; shift 2 ;;
    --iommu) iommu=${2:?--iommu needs intel or amd}; shift 2 ;;
    --aia) aia=1; shift ;;
    *) echo "qemu.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
if (( $# < 4 )); then
  sed -n '4p' "$0" >&2
  exit 2
fi
arch=$1 esp=$2 work=$3 edk2=$4
shift 4

mkdir -p "$work"

# Copy a firmware vars template into the work dir once, padded if needed.
vars() {
  local src=$1 dst=$work/$2 size=${3:-}
  if [[ ! -f $dst ]]; then
    cp "$src" "$dst"
    [[ -n $size ]] && truncate -s "$size" "$dst"
  fi
  echo "$dst"
}

disk=(-drive "if=none,format=raw,file=fat:rw:$esp,id=esp" -device virtio-blk-pci,drive=esp)

case $arch in
  amd64)
    # edu (00:10.0): a PCI device with MSI (K9d) and DMA for the boot
    # tests, behind QEMU's VT-d (K12a) or AMD-Vi (K12b), which must come
    # before the other devices.
    # VT-d with interrupt remapping (K12f) under TCG; KVM refuses it unless
    # the irqchip is split (the IOAPIC in QEMU), which would change every
    # interrupt timing the bench records, so KVM boots keep it off.
    intremap=on
    [[ " $* " == *" kvm "* ]] && intremap=off
    case $iommu in
      intel) iommu_device=intel-iommu,intremap=$intremap; [[ $intremap == on ]] && iommu_device+=,eim=on ;;
      amd) iommu_device=amd-iommu,intremap=$intremap,dma-remap=on ;;
      amd-xt) iommu_device=amd-iommu,intremap=on,xtsup=on,dma-remap=on ;;
      *) echo "qemu.sh: --iommu takes intel, amd or amd-xt" >&2; exit 2 ;;
    esac
    qemu=(qemu-system-x86_64 -machine q35 -cpu max -device "$iommu_device" -device edu,addr=0x10
          -drive "if=pflash,format=raw,readonly=on,file=$edk2/ovmf/OVMF_CODE.fd"
          -drive "if=pflash,format=raw,file=$(vars "$edk2/ovmf/OVMF_VARS.fd" amd64-vars.fd)")
    ;;
  arm64)
    # ramfb gives the firmware a linear GOP framebuffer.
    # edu: DMA through the SMMUv3 for the IOMMU boot test (K12c).
    qemu=(qemu-system-aarch64 -machine virt,acpi=on,iommu=smmuv3,gic-version=3 -cpu max -device ramfb
          -device edu,addr=0x10
          -drive "if=pflash,format=raw,readonly=on,file=$edk2/aarch64/QEMU_EFI-pflash.raw"
          -drive "if=pflash,format=raw,file=$(vars "$edk2/aarch64/vars-template-pflash.raw" arm64-vars.raw)")
    ;;
  rv64)
    # The virt machine wants both flash images padded to 32 MiB.
    if [[ ! -f $work/rv64-code.fd ]]; then
      cp "$edk2/riscv/RISCV_VIRT_CODE.fd" "$work/rv64-code.fd"
      truncate -s 32M "$work/rv64-code.fd"
    fi
    # -cpu max has Svpbmt (memory types in page tables); the default CPU doesn't.
    # A RISC-V IOMMU and edu behind it (K12e). The PCI one: QEMU 10.2 puts
    # only it in the RIMT (iommu-sys=on makes the device, no RIMT). At slot
    # 8, so the others keep their slots, and below edu: the RIMT routes the
    # requester ids above the IOMMU's own.
    # --iommu base: without interrupt remapping (no MSI_FLAT), so 32-byte
    # device contexts in a 2-level directory instead of 64-byte in 3.
    iommu_options=
    case $iommu in
      intel) ;;
      base) iommu_options=,intremap=off ;;
      *) echo "qemu.sh: --iommu on rv64 takes base" >&2; exit 2 ;;
    esac
    machine=virt,acpi=on
    [[ -n $aia ]] && machine+=,aia=aplic-imsic
    qemu=(qemu-system-riscv64 -machine "$machine" -cpu max -device ramfb
          -device "riscv-iommu-pci,addr=0x8$iommu_options" -device edu,addr=0x10
          -drive "if=pflash,format=raw,unit=0,readonly=on,file=$work/rv64-code.fd"
          -drive "if=pflash,format=raw,unit=1,file=$(vars "$edk2/riscv/RISCV_VIRT_VARS.fd" rv64-vars.fd 32M)")
    ;;
  *)
    echo "qemu.sh: unknown arch '$arch'" >&2
    exit 2
    ;;
esac

# virtio-rng: edk2 offers EFI_RNG_PROTOCOL over it, the CPRNG's seed (K11b).
qemu+=(-m 512M -smp 4 -net none "${disk[@]}" -device virtio-rng-pci)

if [[ -n $expect ]]; then
  monitor=(-monitor none)
  if [[ -n $screendump || -n $registers_on ]]; then
    socket=$work/monitor.sock
    rm -f "$socket"
    monitor=(-monitor "unix:$socket,server=on,wait=off")
  fi
  # A guest power-off pauses QEMU instead of ending it, so the screen can
  # still be read once the line is seen.
  [[ -n $screendump ]] && monitor+=(-action shutdown=pause)
  coproc vm { exec timeout 90 "${qemu[@]}" -display none -serial stdio "${monitor[@]}" -no-reboot "$@" 2>&1; }
  pid=$vm_PID  # bash unsets vm_PID when the coproc ends
  kaslr_image=()
  status=1
  while IFS= read -r line <&"${vm[0]}"; do
    printf '%s\n' "$line"
    # KASLR: where the kernel runs, so backtraces can name link addresses.
    if [[ $line =~ kaslr:\ image\ (0x[0-9a-f]+)-(0x[0-9a-f]+),\ link\ (0x[0-9a-f]+) ]]; then
      kaslr_image=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
    fi
    if [[ -n $registers_on ]]; then
      IFS='|' read -ra triggers <<< "$registers_on"
      for trigger in "${triggers[@]}"; do
        if [[ $line == *"$trigger"* ]]; then
          python3 -I "$(dirname "$0")/qemu-monitor.py" "$socket" backtrace "${kaslr_image[@]}" || true
          registers_on=
          break
        fi
      done
    fi
    # The guest turned itself off without the line: no point waiting.
    if [[ $line == "croi kernel: powering off"* || $line == "croi kernel: rebooting"* ]] &&
       [[ $line != *"$expect"* ]]; then
      break
    fi
    if [[ $line == *"$expect"* ]]; then
      status=0
      if [[ -n $screendump ]]; then
        rm -f "$screendump"
        python3 -I "$(dirname "$0")/qemu-monitor.py" "$socket" screendump "$screendump" || status=1
      fi
      break
    fi
  done
  if (( status != 0 )); then
    echo "qemu.sh: '$expect' not seen" >&2
  elif [[ -n $exits ]]; then
    # The rest of the console, until QEMU exits (EOF) or the timeout kills it.
    while IFS= read -r line <&"${vm[0]}"; do printf '%s\n' "$line"; done
    wait "$pid" 2>/dev/null && exited=0 || exited=$?
    if (( exited != 0 )); then
      echo "qemu.sh: QEMU didn't exit by itself (status $exited)" >&2
      status=1
    fi
    exit $status
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  exit $status
else
  exec "${qemu[@]}" -nographic "$@"
fi
