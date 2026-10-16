/* Layout for Grain user programs: text, read-only data and data in separate
 * pages so each gets its own permissions. */
ENTRY(_start)

PHDRS {
    text PT_LOAD FLAGS(5);   /* R X */
    rodata PT_LOAD FLAGS(4); /* R   */
    data PT_LOAD FLAGS(6);   /* R W */
}

SECTIONS
{
    . = 0x10000;
    .text : { KEEP(*(.text._start)) *(.text .text.*) } :text
    . = ALIGN(4K);
    .rodata : { *(.srodata .srodata.*) *(.rodata .rodata.*) } :rodata
    . = ALIGN(4K);
    .data : { *(.sdata .sdata.*) *(.data .data.*) } :data
    .bss : { *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON) } :data
    /DISCARD/ : { *(.eh_frame*) *(.comment) }
}
