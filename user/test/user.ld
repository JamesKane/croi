/* The boot self-test's user program: a static binary at the address the
   kernel maps it (UserSelfTest.codeAt), code and constants only (it is
   mapped read/execute, so no writable data). */
ENTRY(_start)
SECTIONS {
  . = 0x1000000;
  .text : { *(.text.start) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data : { *(.data .data.* .sdata .sdata.*) }
  .bss : { *(.bss .bss.* .sbss .sbss.* COMMON) }
  ASSERT(SIZEOF(.data) + SIZEOF(.bss) == 0, "user test: no writable data allowed")
  /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame*) *(.riscv.attributes) }
}
