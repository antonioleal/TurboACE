/* TurboACE SD soft CPU: memory layout. Program and data in one 48K block RAM,
 * loaded with the FPGA bitstream (register-map.md section 8, decision 30).
 * Measured: RV32IC about 36K, RV32I about 47K, plus the stack (deepest call
 * chains about 2K); the link fails unless STACK_SIZE is left free. */
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 48K
}

SECTIONS
{
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*) } > RAM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss  : { _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > RAM
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
    STACK_SIZE = 4K;
    ASSERT(_bss_end + STACK_SIZE <= _stack_top, "firmware too big: less than 4K left for the stack")
}
