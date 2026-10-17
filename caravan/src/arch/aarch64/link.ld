/* Caravan kernel layout for AArch64 (QEMU virt).
 *
 * QEMU loads the ELF at its physical addresses (RAM starts at 0x40000000,
 * the device tree sits at its start) and enters at _start, at EL1. The
 * kernel is linked to run at 0xffffffff40200000 (TTBR1) and loaded at
 * 0x40200000; boot.zig maps both before jumping up. All of physical memory
 * is also mapped at 0xffffffc000000000 (the physmap). */
OUTPUT_ARCH(aarch64)
ENTRY(_start)

KERNEL_PHYS = 0x40200000;
KERNEL_VIRT = 0xffffffff40200000;
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
        *(.rodata .rodata.*)
    }
    .data : AT(ADDR(.data) - KERNEL_OFFSET) ALIGN(4K) {
        *(.data .data.*)
    }
    .bss (NOLOAD) : AT(ADDR(.bss) - KERNEL_OFFSET) ALIGN(4K) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }
    /* One 64 KiB stack per core (up to 16). */
    .stacks (NOLOAD) : AT(ADDR(.stacks) - KERNEL_OFFSET) ALIGN(4K) {
        __stacks_start = .;
        . += 16 * 64K;
        __stacks_end = .;
    }

    __kernel_end = .;

    /DISCARD/ : { *(.eh_frame*) *(.comment) }
}
