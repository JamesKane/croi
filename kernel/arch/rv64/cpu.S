// rv64 CPU primitives Swift can't express: interrupt masking and the
// spin-wait hint. See kernel.h.

#define SSTATUS_SIE 0x2

.section .text.arch_cpu, "ax", %progbits

// uint64_t arch_interrupts_save(void): sstatus before clearing SIE.
.globl arch_interrupts_save
.type arch_interrupts_save, %function
arch_interrupts_save:
    csrrci  a0, sstatus, SSTATUS_SIE
    ret
.size arch_interrupts_save, . - arch_interrupts_save

// void arch_interrupts_restore(uint64_t state): only SIE is restored.
.globl arch_interrupts_restore
.type arch_interrupts_restore, %function
arch_interrupts_restore:
    andi    a0, a0, SSTATUS_SIE
    csrs    sstatus, a0
    ret
.size arch_interrupts_restore, . - arch_interrupts_restore

// bool arch_interrupts_enabled(void)
.globl arch_interrupts_enabled
.type arch_interrupts_enabled, %function
arch_interrupts_enabled:
    csrr    a0, sstatus
    srli    a0, a0, 1
    andi    a0, a0, 1
    ret
.size arch_interrupts_enabled, . - arch_interrupts_enabled

// void arch_spin_pause(void): Zihintpause `pause`, a FENCE hint (no-op)
// on harts without the extension.
.globl arch_spin_pause
.type arch_spin_pause, %function
arch_spin_pause:
    .insn i 0x0f, 0, x0, x0, 0x010
    ret
.size arch_spin_pause, . - arch_spin_pause

// void arch_tlb_invalidate_page(uint64_t va): this hart, all levels for va.
.globl arch_tlb_invalidate_page
.type arch_tlb_invalidate_page, %function
arch_tlb_invalidate_page:
    sfence.vma a0, zero
    ret
.size arch_tlb_invalidate_page, . - arch_tlb_invalidate_page

// void arch_set_percpu(uint64_t percpu): tp holds it in the kernel.
.globl arch_set_percpu
.type arch_set_percpu, %function
arch_set_percpu:
    mv      tp, a0
    ret
.size arch_set_percpu, . - arch_set_percpu

// uint64_t arch_percpu(void)
.globl arch_percpu
.type arch_percpu, %function
arch_percpu:
    mv      a0, tp
    ret
.size arch_percpu, . - arch_percpu

// uint64_t arch_cpu_hardware_id(void): unknowable in S-mode.
.globl arch_cpu_hardware_id
.type arch_cpu_hardware_id, %function
arch_cpu_hardware_id:
    li      a0, 0
    ret
.size arch_cpu_hardware_id, . - arch_cpu_hardware_id

// Caches are coherent with uncached accesses on RISC-V platforms we run on.
.globl arch_clean_dcache
.type arch_clean_dcache, %function
arch_clean_dcache:
    ret
.size arch_clean_dcache, . - arch_clean_dcache

// void arch_idle(void): interrupts on, wait for one, forever.
.globl arch_idle
.type arch_idle, %function
arch_idle:
    csrsi   sstatus, 0x2            // SIE
1:  wfi
    j       1b
.size arch_idle, . - arch_idle

// void arch_wait_for_interrupt(void): wfi wakes on a pending enabled
// interrupt whatever sstatus.SIE says; setting SIE then takes it.
.globl arch_wait_for_interrupt
.type arch_wait_for_interrupt, %function
arch_wait_for_interrupt:
    wfi
    csrsi   sstatus, 0x2
    csrci   sstatus, 0x2
    ret
.size arch_wait_for_interrupt, . - arch_wait_for_interrupt

// void arch_tlb_invalidate_all(void): this hart.
.globl arch_tlb_invalidate_all
.type arch_tlb_invalidate_all, %function
arch_tlb_invalidate_all:
    sfence.vma
    ret
.size arch_tlb_invalidate_all, . - arch_tlb_invalidate_all

// void arch_rv_sie_set(uint64_t mask) / void arch_rv_sie_clear(uint64_t mask)
// void arch_rv_sip_clear(uint64_t mask)
.globl arch_rv_sie_set
.type arch_rv_sie_set, %function
arch_rv_sie_set:
    csrs    sie, a0
    ret
.size arch_rv_sie_set, . - arch_rv_sie_set

.globl arch_rv_sie_clear
.type arch_rv_sie_clear, %function
arch_rv_sie_clear:
    csrc    sie, a0
    ret
.size arch_rv_sie_clear, . - arch_rv_sie_clear

.globl arch_rv_sip_clear
.type arch_rv_sip_clear, %function
arch_rv_sip_clear:
    csrc    sip, a0
    ret
.size arch_rv_sip_clear, . - arch_rv_sip_clear

// void arch_interrupts_enable(void)
.globl arch_interrupts_enable
.type arch_interrupts_enable, %function
arch_interrupts_enable:
    csrsi   sstatus, 0x2
    ret
.size arch_interrupts_enable, . - arch_interrupts_enable

// uint64_t arch_counter_read(void): the time CSR.
.globl arch_counter_read
.type arch_counter_read, %function
arch_counter_read:
    fence   iorw, iorw
    rdtime  a0
    ret
.size arch_counter_read, . - arch_counter_read

// uint32_t arch_cpu_core_type(void): nothing to tell cores apart by yet.
.globl arch_cpu_core_type
.type arch_cpu_core_type, %function
arch_cpu_core_type:
    li      a0, 0
    ret
.size arch_cpu_core_type, . - arch_cpu_core_type

// uint64_t arch_rv_vlenb(void): sstatus.VS (bits 10:9) Initial for the
// read, then Off again.
.globl arch_rv_vlenb
.type arch_rv_vlenb, %function
arch_rv_vlenb:
    li      t0, (1 << 9)
    csrs    sstatus, t0
    csrr    a0, 0xc22                   // vlenb
    li      t0, (3 << 9)
    csrc    sstatus, t0
    ret
.size arch_rv_vlenb, . - arch_rv_vlenb

// --- User address spaces (aspace.h) --------------------------------------

// satp = MODE Sv39 (8) | ASID | root PPN.
.globl arch_switch_user_tables
.type arch_switch_user_tables, %function
arch_switch_user_tables:
    srli    a0, a0, 12
    slli    a1, a1, 44
    or      a0, a0, a1
    li      t0, 8
    slli    t0, t0, 60
    or      a0, a0, t0
    csrw    satp, a0
    beqz    a2, 1f
    sfence.vma
1:  ret
.size arch_switch_user_tables, . - arch_switch_user_tables

.globl arch_tlb_invalidate_asid
.type arch_tlb_invalidate_asid, %function
arch_tlb_invalidate_asid:
    sfence.vma zero, a0
    ret
.size arch_tlb_invalidate_asid, . - arch_tlb_invalidate_asid

.globl arch_user_access_begin
.type arch_user_access_begin, %function
arch_user_access_begin:
    li      t0, (1 << 18)               // sstatus.SUM
    csrs    sstatus, t0
    ret
.size arch_user_access_begin, . - arch_user_access_begin

.globl arch_user_access_end
.type arch_user_access_end, %function
arch_user_access_end:
    li      t0, (1 << 18)
    csrc    sstatus, t0
    ret
.size arch_user_access_end, . - arch_user_access_end

// uint64_t arch_user_protection_enable(void): SUM is clear except inside
// the accessors, so S-mode can't touch U pages anyway; and never execute
// them (U pages can't be executed in S-mode at all).
.globl arch_user_protection_enable
.type arch_user_protection_enable, %function
arch_user_protection_enable:
    li      t0, (1 << 18)
    csrc    sstatus, t0
    li      a0, 1
    ret
.size arch_user_protection_enable, . - arch_user_protection_enable

// ASIDLEN: write all ones to satp.ASID and count what sticks (the spec's
// probe), then put satp back.
.globl arch_asid_bits
.type arch_asid_bits, %function
arch_asid_bits:
    csrr    t0, satp
    li      t1, 0xffff
    slli    t1, t1, 44
    or      t2, t0, t1
    csrw    satp, t2
    csrr    t2, satp
    csrw    satp, t0
    sfence.vma
    and     t2, t2, t1
    srli    t2, t2, 44
    li      a0, 0
2:  beqz    t2, 3f
    addi    a0, a0, 1
    srli    t2, t2, 1
    j       2b
3:  ret
.size arch_asid_bits, . - arch_asid_bits

// --- Cache maintenance (cache.h) -----------------------------------------

// void arch_cache_op(a0 addr, a1 size, a2 op, a3 line): Zicbom cbo.clean /
// cbo.inval / cbo.flush on (a0), as raw encodings (rs1 = a0).
.globl arch_cache_op
.type arch_cache_op, %function
arch_cache_op:
    beqz    a3, 9f
    add     a1, a0, a1                  // end
    addi    t0, a3, -1
    not     t0, t0
    and     a0, a0, t0                  // first line
    fence   rw, rw
    li      t0, 1
    beq     a2, t0, 1f
    li      t0, 2
    beq     a2, t0, 2f
3:  .4byte  0x0025200f                  // cbo.flush (a0)
    add     a0, a0, a3
    bltu    a0, a1, 3b
    j       8f
1:  .4byte  0x0015200f                  // cbo.clean (a0)
    add     a0, a0, a3
    bltu    a0, a1, 1b
    j       8f
2:  .4byte  0x0005200f                  // cbo.inval (a0)
    add     a0, a0, a3
    bltu    a0, a1, 2b
8:  fence   rw, rw
9:  ret
.size arch_cache_op, . - arch_cache_op

.globl arch_cache_line
.type arch_cache_line, %function
arch_cache_line:
    li      a0, 0
    ret
.size arch_cache_line, . - arch_cache_line

// void arch_user_counter_enable(void): scounteren.TM (bit 1): U-mode may
// read `time` (firmware's mcounteren must allow it too; OpenSBI does).
.globl arch_user_counter_enable
.type arch_user_counter_enable, %function
arch_user_counter_enable:
    csrsi   scounteren, 2
    ret
.size arch_user_counter_enable, . - arch_user_counter_enable

// --- User extended state (xstate.h) ---------------------------------------
// Layout: f0-f31, fcsr (264 bytes); with V (vlenb bytes per register):
// v0-v31, then vstart, vl, vtype, vcsr (8 bytes each). The kernel turns FS
// and VS on to save and restore; user threads run with them on.

.option push
.option arch, +d, +v

#define SSTATUS_FS_DIRTY (3 << 13)
#define SSTATUS_VS_DIRTY (3 << 9)

// void arch_xstate_enable(void): nothing per hart beyond FS/VS, which
// save/restore and user entry set.
.globl arch_xstate_enable
.type arch_xstate_enable, %function
arch_xstate_enable:
    ret
.size arch_xstate_enable, . - arch_xstate_enable

// void arch_xstate_save(void *area)
.globl arch_xstate_save
.type arch_xstate_save, %function
arch_xstate_save:
    li      t0, SSTATUS_FS_DIRTY | SSTATUS_VS_DIRTY
    csrs    sstatus, t0
    .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    fsd     f\n, (\n * 8)(a0)
    .endr
    frcsr   t1
    sd      t1, 256(a0)
    la      t2, croi_xstate_config
    ld      t2, 0(t2)                       // vlenb, or 0
    beqz    t2, 1f
    csrr    t3, vstart
    csrr    t4, vl
    csrr    t5, vtype
    csrr    t6, vcsr
    addi    a1, a0, 264
    vs8r.v  v0, (a1)
    slli    t0, t2, 3
    add     a1, a1, t0
    vs8r.v  v8, (a1)
    add     a1, a1, t0
    vs8r.v  v16, (a1)
    add     a1, a1, t0
    vs8r.v  v24, (a1)
    add     a1, a1, t0
    sd      t3, 0(a1)
    sd      t4, 8(a1)
    sd      t5, 16(a1)
    sd      t6, 24(a1)
1:  ret
.size arch_xstate_save, . - arch_xstate_save

// void arch_xstate_restore(const void *area)
.globl arch_xstate_restore
.type arch_xstate_restore, %function
arch_xstate_restore:
    li      t0, SSTATUS_FS_DIRTY | SSTATUS_VS_DIRTY
    csrs    sstatus, t0
    .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    fld     f\n, (\n * 8)(a0)
    .endr
    ld      t1, 256(a0)
    fscsr   t1
    la      t2, croi_xstate_config
    ld      t2, 0(t2)
    beqz    t2, 1f
    addi    a1, a0, 264
    slli    t0, t2, 3
    vl8re8.v v0, (a1)
    add     a1, a1, t0
    vl8re8.v v8, (a1)
    add     a1, a1, t0
    vl8re8.v v16, (a1)
    add     a1, a1, t0
    vl8re8.v v24, (a1)
    add     a1, a1, t0
    ld      t4, 8(a1)                       // vl
    ld      t5, 16(a1)                      // vtype
    vsetvl  zero, t4, t5
    ld      t3, 0(a1)
    csrw    vstart, t3
    ld      t6, 24(a1)
    csrw    vcsr, t6
1:  ret
.size arch_xstate_restore, . - arch_xstate_restore

.option pop
