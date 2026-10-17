//! First instructions at EL1 (or EL2, which drops to EL1), for the boot core
//! and secondary cores.
//!
//! Both run at their physical load address with the MMU off. They build
//! (boot core) or reuse (secondaries) the boot tables:
//!
//!   TTBR0  boot_ident: an identity gigablock at 0x4000_0000, so the next
//!          instruction still works (replaced by an empty table once up)
//!   TTBR1  boot_root: 0xffff_ffc0_0000_0000 maps the first 64 GiB of
//!          physical memory (the physmap; GiB 0 as device memory, it holds
//!          only devices on QEMU virt), and 0xffff_ffff_4000_0000 the
//!          kernel image's gigablock
//!
//! then turn the MMU on and jump to the kernel's linked (virtual) address.
//! Everything here is pc-relative, so it works at either address.
//!
//! QEMU loads a bare ELF kernel with no boot protocol: x0 is 0 and the
//! device tree sits at the start of RAM. A loader that passes one in x0 wins.

pub const kernel_offset: u64 = 0xffff_ffff_0000_0000; // virtual - physical
pub const physmap_base: u64 = 0xffff_ffc0_0000_0000;
pub const physmap_gigabytes = 64;
pub const stack_size = 64 * 1024;
pub const ram_base: u64 = 0x4000_0000;

/// The kernel's TTBR1 table.
pub export var boot_root: [512]u64 align(4096) linksection(".data") = @splat(0);
/// The identity map used while turning the MMU on.
pub export var boot_ident: [512]u64 align(4096) linksection(".data") = @splat(0);
/// TTBR0 when no thread runs: nothing mapped below the kernel.
pub export var empty_root: [512]u64 align(4096) linksection(".data") = @splat(0);

comptime {
    asm (
        \\.section .text.boot, "ax"
        \\.global _start
        \\_start:
        \\    mov x19, x0
        \\    cbnz x19, 1f
        \\    mov x19, #0x40000000
        \\1:  bl .Lel1
        \\    mrs x20, mpidr_el1
        \\    and x20, x20, #0xffffff
        // Physmap: entries 256..319; GiB 0 is device memory.
        \\    adrp x0, boot_root
        \\    add x0, x0, :lo12:boot_root
        \\    add x1, x0, #2048
        \\    ldr x2, =0x0060000000000405
        \\    str x2, [x1], #8
        \\    mov x3, #1
        \\    ldr x4, =0x0060000000000701
        \\2:  lsl x5, x3, #30
        \\    orr x5, x5, x4
        \\    str x5, [x1], #8
        \\    add x3, x3, #1
        \\    cmp x3, #64
        \\    b.lo 2b
        // The kernel image (entry 509) and the identity map share GiB 1.
        \\    ldr x2, =0x0040000040000701
        \\    str x2, [x0, #4072]
        \\    adrp x1, boot_ident
        \\    add x1, x1, :lo12:boot_ident
        \\    str x2, [x1, #8]
        // Clear .bss (physical addresses; nothing else is running yet).
        \\    adrp x1, __bss_start
        \\    add x1, x1, :lo12:__bss_start
        \\    adrp x2, __bss_end
        \\    add x2, x2, :lo12:__bss_end
        \\3:  cmp x1, x2
        \\    b.hs 4f
        \\    str xzr, [x1], #8
        \\    b 3b
        // Boot core uses stack 0; x21 = 0 marks the boot path.
        \\4:  adrp x1, __stacks_start
        \\    add x1, x1, :lo12:__stacks_start
        \\    mov x2, #0x10000
        \\    add x1, x1, x2
        \\    mov sp, x1
        \\    mov x21, #0
        \\    b .Lenable_mmu
        \\
        // Secondary cores (PSCI CPU_ON): x0 = context = logical index.
        \\.global _start_secondary
        \\_start_secondary:
        \\    mov x22, x0
        \\    bl .Lel1
        \\    mrs x20, mpidr_el1
        \\    and x20, x20, #0xffffff
        \\    adrp x1, __stacks_start
        \\    add x1, x1, :lo12:__stacks_start
        \\    add x2, x22, #1
        \\    lsl x2, x2, #16
        \\    add x1, x1, x2
        \\    mov sp, x1
        \\    mov x21, #1
        \\
        \\.Lenable_mmu:
        // MAIR: attribute 0 normal write-back, attribute 1 device-nGnRnE.
        \\    mov x1, #0xff
        \\    msr mair_el1, x1
        // TCR: 39-bit halves, 4 KiB granules, write-back walks, inner
        // shareable; the physical address size the core supports.
        \\    ldr x1, =0xb5193519
        \\    mrs x2, id_aa64mmfr0_el1
        \\    and x2, x2, #7
        \\    bfi x1, x2, #32, #3
        \\    msr tcr_el1, x1
        \\    adrp x1, boot_ident
        \\    add x1, x1, :lo12:boot_ident
        \\    msr ttbr0_el1, x1
        \\    adrp x1, boot_root
        \\    add x1, x1, :lo12:boot_root
        \\    msr ttbr1_el1, x1
        // No floating point or SIMD anywhere (the kernel and programs are
        // built without it): such an instruction traps.
        \\    msr cpacr_el1, xzr
        \\    isb
        \\    tlbi vmalle1
        \\    dsb nsh
        \\    isb
        // SCTLR: MMU, caches; EL0 may use DC ZVA, CTR, cache maintenance,
        // WFI and WFE.
        \\    ldr x1, =0x34d5d805
        \\    msr sctlr_el1, x1
        \\    isb
        // Move pc and sp to the kernel's virtual addresses.
        \\    ldr x1, =0xffffffff00000000
        \\    add sp, sp, x1
        \\    adr x2, .Lhigh
        \\    add x2, x2, x1
        \\    br x2
        \\.Lhigh:
        \\    mov x0, x20
        \\    cbnz x21, 5f
        \\    mov x1, x19
        \\    b kmain
        \\5:  mov x1, x22
        \\    b kmainSecondary
        \\
        // From EL2 (a hypervisor-capable boot): run the kernel at EL1 with
        // the timer and counter its own. Returns at EL1.
        \\.Lel1:
        \\    mrs x9, CurrentEL
        \\    cmp x9, #8
        \\    b.ne 6f
        \\    mov x9, #(1 << 31)
        \\    msr hcr_el2, x9
        \\    mov x9, #3
        \\    msr cnthctl_el2, x9
        \\    msr cntvoff_el2, xzr
        \\    mov x9, #0x3c5
        \\    msr spsr_el2, x9
        \\    msr elr_el2, x30
        \\    eret
        \\6:  ret
        \\.ltorg
    );
}
