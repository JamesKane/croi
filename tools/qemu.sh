#!/usr/bin/env bash
# Boot a croi EFI system partition under QEMU with edk2 firmware.
#
#   qemu.sh [--test <text>] [--screendump <file.ppm>] [--registers-on <text>] <amd64|arm64|rv64> <esp-dir> <work-dir> <edk2-dir> [qemu args...]
#
# The ESP directory is served as a virtual FAT drive. Writable firmware
# variable stores are copied into <work-dir> on first use. With --test the
# run is headless and console output is copied to stdout; it succeeds as
# soon as a line containing <text> appears and fails after a timeout. With
# --screendump (test mode only) the display is saved as a PPM at that point.
# With --registers-on (test mode only), the first line containing that text
# prints every CPU's PC and frame-pointer backtrace (qemu-monitor.py): where
# each CPU is when a lockup is reported. Alternatives are separated by '|'.

set -euo pipefail

expect=
screendump=
registers_on=
while [[ ${1:-} == --* ]]; do
  case $1 in
    --test) expect=${2:?--test needs the text to wait for}; shift 2 ;;
    --screendump) screendump=${2:?--screendump needs a file}; shift 2 ;;
    --registers-on) registers_on=${2:?--registers-on needs the text to wait for}; shift 2 ;;
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
    qemu=(qemu-system-x86_64 -machine q35 -cpu max
          -drive "if=pflash,format=raw,readonly=on,file=$edk2/ovmf/OVMF_CODE.fd"
          -drive "if=pflash,format=raw,file=$(vars "$edk2/ovmf/OVMF_VARS.fd" amd64-vars.fd)")
    ;;
  arm64)
    # ramfb gives the firmware a linear GOP framebuffer.
    qemu=(qemu-system-aarch64 -machine virt,acpi=on,iommu=smmuv3,gic-version=3 -cpu max -device ramfb
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
    qemu=(qemu-system-riscv64 -machine virt,acpi=on -cpu max -device ramfb
          -drive "if=pflash,format=raw,unit=0,readonly=on,file=$work/rv64-code.fd"
          -drive "if=pflash,format=raw,unit=1,file=$(vars "$edk2/riscv/RISCV_VIRT_VARS.fd" rv64-vars.fd 32M)")
    ;;
  *)
    echo "qemu.sh: unknown arch '$arch'" >&2
    exit 2
    ;;
esac

qemu+=(-m 512M -smp 4 -net none "${disk[@]}")

if [[ -n $expect ]]; then
  monitor=(-monitor none)
  if [[ -n $screendump || -n $registers_on ]]; then
    socket=$work/monitor.sock
    rm -f "$socket"
    monitor=(-monitor "unix:$socket,server=on,wait=off")
  fi
  coproc vm { exec timeout 90 "${qemu[@]}" -display none -serial stdio "${monitor[@]}" -no-reboot "$@" 2>&1; }
  status=1
  while IFS= read -r line <&"${vm[0]}"; do
    printf '%s\n' "$line"
    if [[ -n $registers_on ]]; then
      IFS='|' read -ra triggers <<< "$registers_on"
      for trigger in "${triggers[@]}"; do
        if [[ $line == *"$trigger"* ]]; then
          python3 -I "$(dirname "$0")/qemu-monitor.py" "$socket" backtrace || true
          registers_on=
          break
        fi
      done
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
  kill "$vm_PID" 2>/dev/null || true
  wait "$vm_PID" 2>/dev/null || true
  (( status == 0 )) || echo "qemu.sh: '$expect' not seen" >&2
  exit $status
else
  exec "${qemu[@]}" -nographic "$@"
fi
