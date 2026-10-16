//! First instructions executed in S-mode: set up a stack, clear .bss, enter Zig.

comptime {
    asm (
        \\.section .text.boot, "ax"
        \\.global _start
        \\_start:
        \\    la sp, __boot_stack_top
        \\    la t0, __bss_start
        \\    la t1, __bss_end
        \\1:  bgeu t0, t1, 2f
        \\    sd zero, 0(t0)
        \\    addi t0, t0, 8
        \\    j 1b
        \\2:  tail kmain
    );
}
