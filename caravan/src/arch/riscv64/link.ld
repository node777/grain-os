/* Caravan kernel layout for RISC-V (Sv39).
 *
 * OpenSBI enters S-mode at physical 0x80200000 with a0 = hart id and
 * a1 = physical address of the device tree. The kernel is linked to run at
 * 0xffffffff80200000 (the top 2 GiB) and loaded at its physical address;
 * boot.zig maps both before jumping up. All of physical memory is also
 * mapped at 0xffffffc000000000 (the physmap). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

KERNEL_PHYS = 0x80200000;
KERNEL_VIRT = 0xffffffff80200000;
KERNEL_OFFSET = KERNEL_VIRT - KERNEL_PHYS;

SECTIONS
{
    . = KERNEL_VIRT;
    __kernel_start = .;

    .text : AT(ADDR(.text) - KERNEL_OFFSET) ALIGN(4K) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    .rodata : AT(ADDR(.rodata) - KERNEL_OFFSET) ALIGN(4K) {
        *(.srodata .srodata.*)
        *(.rodata .rodata.*)
    }
    .data : AT(ADDR(.data) - KERNEL_OFFSET) ALIGN(4K) {
        *(.sdata .sdata.*)
        *(.data .data.*)
    }
    .bss (NOLOAD) : AT(ADDR(.bss) - KERNEL_OFFSET) ALIGN(4K) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }
    /* One 64 KiB stack per hart (up to 16). */
    .stacks (NOLOAD) : AT(ADDR(.stacks) - KERNEL_OFFSET) ALIGN(4K) {
        __stacks_start = .;
        . += 16 * 64K;
        __stacks_end = .;
    }

    __kernel_end = .;

    /DISCARD/ : { *(.eh_frame*) *(.comment) }
}
