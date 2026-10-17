//! First instructions in S-mode, for the boot hart and secondary harts.
//!
//! Both run at their physical load address with paging off. They build
//! (boot hart) or reuse (secondaries) the boot page table, which maps:
//!
//!   0x0000_0000_8000_0000  identity gigapage, so the next instruction still works
//!   0xffff_ffc0_0000_0000  all of the first 64 GiB of physical memory (physmap)
//!   0xffff_ffff_8000_0000  the kernel image (same gigapage as the identity map)
//!
//! then turn on Sv39 and jump to the kernel's linked (virtual) address.
//! Everything here uses pc-relative addressing, which works at either address.
//! a0, a1 and a2 (hart id, device tree, measured-boot record) pass through
//! untouched to kmain.

pub const kernel_offset: u64 = 0xffff_ffff_0000_0000; // virtual - physical
pub const physmap_base: u64 = 0xffff_ffc0_0000_0000;
pub const physmap_gigabytes = 64;
pub const stack_size = 64 * 1024;

/// The boot root table. User root tables copy its upper half.
pub export var boot_root: [512]u64 align(4096) linksection(".data") = @splat(0);

comptime {
    asm (
        \\.section .text.boot, "ax"
        \\.global _start
        \\_start:
        // Physmap: entries 256..319 = gigapages 0..63 (V R W X G A D = 0xEF).
        \\    la t0, boot_root
        \\    addi t4, t0, 2047
        \\    addi t4, t4, 1
        \\    li t1, 0
        \\    li t2, 64
        \\    li t3, 0xEF
        \\1:  slli t5, t1, 28
        \\    or t5, t5, t3
        \\    sd t5, 0(t4)
        \\    addi t4, t4, 8
        \\    addi t1, t1, 1
        \\    blt t1, t2, 1b
        // Identity (index 2) and kernel (index 510) both map PA 0x8000_0000.
        \\    li t5, (2 << 28) | 0xEF
        \\    sd t5, 16(t0)
        \\    li t6, 4080
        \\    add t6, t6, t0
        \\    sd t5, 0(t6)
        // Clear .bss (physical addresses; nothing else is running yet).
        \\    la t1, __bss_start
        \\    la t2, __bss_end
        \\2:  bgeu t1, t2, 3f
        \\    sd zero, 0(t1)
        \\    addi t1, t1, 8
        \\    j 2b
        \\3:
        // Boot hart uses stack 0; s1 = 0 marks the boot path.
        \\    la sp, __stacks_start
        \\    li t1, 65536
        \\    add sp, sp, t1
        \\    li s1, 0
        \\    j .Lenable_paging
        \\
        // Secondary harts: a0 = hart id, a1 = opaque = stack index.
        \\.global _start_secondary
        \\_start_secondary:
        \\    li s1, 1
        \\    la sp, __stacks_start
        \\    li t1, 65536
        \\    addi t2, a1, 1
        \\    mul t1, t1, t2
        \\    add sp, sp, t1
        \\    la t0, boot_root
        \\
        \\.Lenable_paging:
        \\    srli t1, t0, 12
        \\    li t2, 8
        \\    slli t2, t2, 60
        \\    or t1, t1, t2
        \\    csrw satp, t1
        \\    sfence.vma
        // Move pc and sp to the kernel's virtual addresses.
        \\    li t1, 0xffffffff00000000
        \\    add sp, sp, t1
        \\    la t2, .Lhigh
        \\    add t2, t2, t1
        \\    jr t2
        \\.Lhigh:
        \\    mv tp, zero
        \\    beqz s1, 4f
        \\    tail kmainSecondary
        \\4: tail kmain
    );
}
