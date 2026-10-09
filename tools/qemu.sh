#!/usr/bin/env bash
# Boot a croi EFI system partition under QEMU with edk2 firmware.
#
#   qemu.sh [--test <text>] <amd64|arm64|rv64> <esp-dir> <work-dir> <edk2-dir> [qemu args...]
#
# The ESP directory is served as a virtual FAT drive. Writable firmware
# variable stores are copied into <work-dir> on first use. With --test the
# run is headless and console output is copied to stdout; it succeeds as
# soon as a line containing <text> appears and fails after a timeout.

set -euo pipefail

expect=
if [[ ${1:-} == --test ]]; then
  expect=${2:?--test needs the text to wait for}
  shift 2
fi
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
    qemu=(qemu-system-aarch64 -machine virt,acpi=on,iommu=smmuv3 -cpu max
          -drive "if=pflash,format=raw,readonly=on,file=$edk2/aarch64/QEMU_EFI-pflash.raw"
          -drive "if=pflash,format=raw,file=$(vars "$edk2/aarch64/vars-template-pflash.raw" arm64-vars.raw)")
    ;;
  rv64)
    # The virt machine wants both flash images padded to 32 MiB.
    if [[ ! -f $work/rv64-code.fd ]]; then
      cp "$edk2/riscv/RISCV_VIRT_CODE.fd" "$work/rv64-code.fd"
      truncate -s 32M "$work/rv64-code.fd"
    fi
    qemu=(qemu-system-riscv64 -machine virt,acpi=on
          -drive "if=pflash,format=raw,unit=0,readonly=on,file=$work/rv64-code.fd"
          -drive "if=pflash,format=raw,unit=1,file=$(vars "$edk2/riscv/RISCV_VIRT_VARS.fd" rv64-vars.fd 32M)")
    ;;
  *)
    echo "qemu.sh: unknown arch '$arch'" >&2
    exit 2
    ;;
esac

qemu+=(-m 512M -smp 2 -net none "${disk[@]}")

if [[ -n $expect ]]; then
  coproc vm { exec timeout 90 "${qemu[@]}" -display none -serial stdio -monitor none -no-reboot "$@" 2>&1; }
  status=1
  while IFS= read -r line <&"${vm[0]}"; do
    printf '%s\n' "$line"
    if [[ $line == *"$expect"* ]]; then
      status=0
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
