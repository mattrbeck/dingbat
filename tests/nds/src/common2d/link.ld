/* ARM9 image for the no-library C test ROMs: loaded and entered at
   0x02000000, everything in one block the header's ARM9 size covers. */
ENTRY(_start)
SECTIONS
{
  . = 0x02000000;
  .text : { *(.text.start) *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  . = ALIGN(4);
  __bss_start = .;
  .bss : { *(.bss*) *(COMMON) }
  . = ALIGN(4);
  __bss_end = .;
  /DISCARD/ : { *(.ARM.exidx*) *(.comment) }
}
