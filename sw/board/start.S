/* ============================================================================
 * Startup and trap code for the board program (roadmap R3.3)
 * ============================================================================
 * Boot mode 2 starts both cores at address 0 in their IMEM. This sets the trap
 * vector and the stack, clears .bss, and calls main. There is no initialised
 * data to copy: the linker script refuses any.
 *
 * No interrupt is enabled, so a trap can only be an exception, in practice an
 * access fault from a load or store the bus ended with ERR (HSI section 8.1).
 * The handler counts it in trap_count and goes on with the next instruction.
 * ========================================================================== */

    .section .text.start, "ax"
    .globl  _start
_start:
    la      t0, trap_entry
    csrw    mtvec, t0
    la      sp, __stack_top
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:  call    main
3:  j       3b

    .align  2
trap_entry:
    addi    sp, sp, -8
    sw      t0, 0(sp)
    sw      t1, 4(sp)
    la      t0, trap_count
    lw      t1, 0(t0)
    addi    t1, t1, 1
    sw      t1, 0(t0)
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    lw      t1, 4(sp)
    lw      t0, 0(sp)
    addi    sp, sp, 8
    mret
