/* The vDSO: header and code from 0, then the three shared pages (mapped
   by the kernel, not part of the image). Position independent: everything
   is reached PC-relatively. */
ENTRY(croi_vdso_clock_monotonic)
SECTIONS {
  . = 0;
  .text : { KEEP(*(.vdso.header)) *(.text .text.*) *(.rodata .rodata.* .srodata .srodata.*) }
  . = ALIGN(4096);
  croi_vdso_code_end = .;
  croi_vdso_time_page = .;
  . += 4096;
  croi_vdso_topology_page = .;
  . += 4096;
  croi_vdso_power_page = .;
  . += 4096;
  .data : { *(.data .data.* .sdata .sdata.*) }
  .bss : { *(.bss .bss.* .sbss .sbss.* COMMON) }
  ASSERT(SIZEOF(.data) + SIZEOF(.bss) == 0, "vdso: no writable data")
  /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame*) *(.riscv.attributes) *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash) *(.dynamic) }
}
