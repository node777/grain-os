/* Aurora is loaded high in RAM (QEMU -kernel), clear of the kernel it loads
 * at 0x80200000 and of the device tree QEMU puts near the top of RAM. It
 * runs with paging off: every address is physical. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x8C000000;
    __aurora_start = .;
    .text : { KEEP(*(.text.start)) *(.text .text.*) }
    .rodata : ALIGN(16) { *(.srodata .srodata.*) *(.rodata .rodata.*) }
    .data : ALIGN(16) { *(.sdata .sdata.*) *(.data .data.*) }
    .bss (NOLOAD) : ALIGN(4096) {
        __bss_start = .;
        *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }
    . = ALIGN(16);
    . += 0x20000;
    __stack_top = .;
    __aurora_end = .;
}
