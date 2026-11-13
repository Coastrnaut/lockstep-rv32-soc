/* ============================================================================
 * Memory map for the board program (HSI section 5)
 * ============================================================================
 * Code and constants in each core's IMEM image, which NEORV32 fills from
 * neorv32_imem_image (boot mode 2), at most 256 words. Variables and the
 * stack in the shared ECC RAM, whose every access goes through the comparator.
 * Only the first 32 KB of the RAM is used, so the smallest RAM profile
 * (g_ram_addr_bits = 12) holds it too.
 * ========================================================================== */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 1K
  RAM  (rw) : ORIGIN = 0x20000000, LENGTH = 32K
}

SECTIONS
{
  .text :
  {
    KEEP(*(.text.start))
    *(.text .text.*)
    *(.rodata .rodata.* .srodata .srodata.*)
    . = ALIGN(4);
  } > IMEM

  .data :
  {
    *(.data .data.* .sdata .sdata.*)
  } > RAM AT > IMEM

  .bss (NOLOAD) :
  {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  __stack_top = ORIGIN(RAM) + LENGTH(RAM);

  /DISCARD/ :
  {
    *(.comment)
    *(.note .note.*)
    *(.eh_frame .eh_frame_hdr)
  }
}

ASSERT(SIZEOF(.data) == 0, "no initialised data: start.S does not copy it")
