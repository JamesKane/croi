// The vDSO's header (shared.h croi_vdso_header_t), at its first byte:
// function offsets as assembler-time differences, so no relocations.

.section .vdso.header, "a"
.balign 16
vdso_header:
    .long   0x53445643              // CROI_VDSO_MAGIC
    .long   1                       // version
    .long   croi_vdso_clock_monotonic - vdso_header
    .long   croi_vdso_topology - vdso_header
    .long   croi_vdso_power - vdso_header
    .long   croi_vdso_code_end - vdso_header
