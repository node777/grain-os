/* Caravan kernel layout for RISC-V. OpenSBI (fw_dynamic/fw_jump) enters S-mode
 * at 0x80200000 with a0 = hart id, a1 = physical address of the device tree. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80200000;
    __kernel_start = .;

    .text : ALIGN(4K) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    .rodata : ALIGN(4K) {
        *(.srodata .srodata.*)
        *(.rodata .rodata.*)
    }
    .data : ALIGN(4K) {
        *(.sdata .sdata.*)
        *(.data .data.*)
    }
    .bss (NOLOAD) : ALIGN(4K) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }
    .stack (NOLOAD) : ALIGN(4K) {
        . += 64K;
        __boot_stack_top = .;
    }

    __kernel_end = .;

    /DISCARD/ : { *(.eh_frame*) *(.comment) }
}
