/*
 * Layout shared by every croi image (loader and kernel): a static PIE with
 * one page-aligned PT_LOAD per permission set (R X, R, R W) so mappings can
 * be W^X. The entry point (-e) and IMAGE_BASE (--defsym) come from CMake.
 *
 * Segment bounds (__image_start, __text_end, __rodata_start, __rodata_end,
 * __data_start, __image_end) let an image map itself.
 *
 * The loader uses IMAGE_BASE=0x1000: ELF addresses are then PE RVAs and the
 * first page is left for the headers tools/elf2efi.py writes.
 */

PHDRS {
  text    PT_LOAD    FLAGS(5);  /* R X */
  rodata  PT_LOAD    FLAGS(4);  /* R   */
  data    PT_LOAD    FLAGS(6);  /* R W */
  dynamic PT_DYNAMIC FLAGS(6);
}

SECTIONS {
  . = IMAGE_BASE;
  __image_start = .;
  .text : { *(.text.boot) *(.text .text.*) } :text
  __text_end = .;

  . = ALIGN(0x1000);
  __rodata_start = .;
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } :rodata
  /* Kernel user-access fixups (instruction, recovery) as 32-bit offsets
     from the entry itself, so they need no relocations. */
  .croi_fixups : { __fixups_start = .; KEEP(*(.croi_fixups)) __fixups_end = .; } :rodata
  /* Swift module hash, used by debuggers to match modules (debug info). */
  .swift_modhash : { KEEP(*(.swift_modhash)) } :rodata
  .dynsym : { *(.dynsym) } :rodata
  .gnu.hash : { *(.gnu.hash) } :rodata
  .hash : { *(.hash) } :rodata
  .dynstr : { *(.dynstr) } :rodata
  .rela.dyn : { *(.rela.dyn .rela.*) } :rodata
  __rodata_end = .;

  . = ALIGN(0x1000);
  __data_start = .;
  .data.rel.ro : { *(.data.rel.ro .data.rel.ro.*) } :data
  .dynamic : { *(.dynamic) } :data :dynamic
  .got : { *(.got .got.*) } :data
  .data : { *(.data .data.* .sdata .sdata.*) } :data
  .bss : { *(.bss .bss.* .sbss .sbss.* COMMON) } :data
  __image_end = .;

  /* Non-loaded metadata. */
  .comment 0 : { *(.comment) }
  .riscv.attributes 0 : { *(.riscv.attributes) }
  .debug_abbrev 0 : { *(.debug_abbrev) }
  .debug_addr 0 : { *(.debug_addr) }
  .debug_aranges 0 : { *(.debug_aranges) }
  .debug_frame 0 : { *(.debug_frame) }
  .debug_info 0 : { *(.debug_info) }
  .debug_line 0 : { *(.debug_line) }
  .debug_line_str 0 : { *(.debug_line_str) }
  .debug_loc 0 : { *(.debug_loc) }
  .debug_loclists 0 : { *(.debug_loclists) }
  .debug_names 0 : { *(.debug_names) }
  .debug_ranges 0 : { *(.debug_ranges) }
  .debug_rnglists 0 : { *(.debug_rnglists) }
  .debug_str 0 : { *(.debug_str) }
  .debug_str_offsets 0 : { *(.debug_str_offsets) }
  .symtab 0 : { *(.symtab) }
  .strtab 0 : { *(.strtab) }
  .shstrtab 0 : { *(.shstrtab) }

  /DISCARD/ : { *(.eh_frame .eh_frame_hdr .note .note.*) *(.interp) }
}
