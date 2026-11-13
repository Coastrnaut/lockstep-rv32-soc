#!/usr/bin/env python3
"""Assemble the RV32I test program for the SoC testbenches into an IMEM image.

The cores run this from reset. It uses the peripherals the way real software
would, and reports what it reads back over the UART, so the testbenches can tell
that stores and loads work on both lockstep cores. Regenerate the image with:

    python sim/scripts/soc_firmware.py
"""
from pathlib import Path

OUTPUT = Path(__file__).parent.parent / "firmware" / "neorv32_imem_image.vhd"
REGISTERS = {"zero": 0, "t0": 5, "t1": 6, "t2": 7, "s0": 8, "s1": 9, "a0": 10, "s2": 18, "s3": 19, "s4": 20,
             "s5": 21, "t3": 28}
CSRS = {"mstatus": 0x300, "mie": 0x304, "mtvec": 0x305, "mepc": 0x341, "mcause": 0x342}
ROM_WORDS = 256
TRAP_ADDRESS = 4
WD_WINDOW_OPEN = 20                    # Watchdog STATUS value once the counter is past 40960

PROGRAM = [
    ("jal", "zero", "main"),

    # Exceptions: the only one this program can meet is an access fault, from a bus
    # ERR (HSI BUS-08 and BUS-09). Count it in s5 and go on with the next instruction.
    "trap:",
    ("csrr", "t3", "mcause"),
    ("srli", "t3", "t3", 31),          # 1 for an interrupt
    ("bne", "t3", "zero", "trap_irq"),
    ("addi", "s5", "s5", 1),
    ("csrr", "t3", "mepc"),
    ("addi", "t3", "t3", 4),
    ("csrw", "mepc", "t3"),
    ("mret",),

    # Interrupts: count them in s1 (CAN_ERROR) and s2 (UART_ERROR), and clear them.
    # A received frame comes in on the same line as CAN_ERROR. Send the low byte of
    # its identifier to the UART, and release it.
    "trap_irq:",
    ("csrr", "t3", "mcause"),
    ("andi", "t3", "t3", 4),           # 7 = MTI has this bit, 3 = MSI does not
    ("bne", "t3", "zero", "trap_uart"),
    ("lw", "t3", 0x328, "s0"),
    ("andi", "t3", "t3", 1),
    ("beq", "t3", "zero", "trap_can_error"),
    ("lw", "t3", 0x318, "s0"),
    ("sw", "t3", 0x400, "s0"),
    ("sw", "zero", 0x328, "s0"),
    ("mret",),
    "trap_can_error:",
    ("sw", "zero", 0x30C, "s0"),
    ("addi", "s1", "s1", 1),
    ("mret",),
    "trap_uart:",
    ("sw", "zero", 0x404, "s0"),
    ("addi", "s2", "s2", 1),
    ("mret",),

    "main:",
    ("lui", "s0", 0x40000),            # s0 = peripheral window
    ("addi", "s1", "zero", 0),
    ("addi", "s2", "zero", 0),
    ("addi", "s5", "zero", 0),
    ("lui", "s4", 0xE),                # s4 = watchdog key, 0xDEAD
    ("addi", "s4", "s4", -339),
    ("addi", "t0", "zero", TRAP_ADDRESS),
    ("csrw", "mtvec", "t0"),
    ("addi", "t0", "zero", 0x88),      # MSI and MTI, never MEI
    ("csrw", "mie", "t0"),
    ("addi", "t0", "zero", 1),         # An interrupt for each received frame
    ("sw", "t0", 0x32C, "s0"),

    # A write to KICK with the wrong value must do nothing. A kick this early would
    # reset the SoC, and the first byte below would come out twice.
    ("sw", "zero", 0x200, "s0"),

    # Start with RESET_SRC as a digit. If it fails parity, as tb_soc_uart_error
    # arranges, wait for UART_ERROR and report that on CAN, because the UART cannot.
    ("lw", "s3", 0x208, "s0"),
    ("addi", "t2", "s3", ord("0")),
    ("sw", "t2", 0x400, "s0"),
    ("lw", "t1", 0x408, "s0"),
    ("bne", "t1", "zero", "parity_good"),
    ("addi", "t0", "zero", 8),         # MIE
    ("csrs", "mstatus", "t0"),
    "wait_irq:",
    ("beq", "s2", "zero", "wait_irq"),
    ("addi", "t0", "zero", 0x0EE),
    ("sw", "t0", 0x300, "s0"),
    ("sw", "t0", 0x314, "s0"),
    ("jal", "zero", "done"),

    "parity_good:",
    ("lw", "t1", 0x404, "s0"),
    ("andi", "t1", "t1", 1),
    ("bne", "t1", "zero", "parity_good"),

    # After a timeout, kick far too early. After an early kick, stop, and leave
    # the watchdog to time out. tb_soc_watchdog follows this round. RESET_SRC
    # never reads 3 by itself: tb_soc_fabric forces it, to run the bus probes.
    ("beq", "s3", "zero", "cold_start"),
    ("addi", "t1", "zero", 3),
    ("beq", "s3", "t1", "fabric"),
    ("addi", "t1", "zero", 2),
    ("bne", "s3", "t1", "done"),
    ("sw", "s4", 0x200, "s0"),
    ("jal", "zero", "done"),

    # Store a word in the RAM and a byte into that word, and read it back. Say 'M'
    # if it held, then the single-bit errors the ECC has corrected, as a digit.
    # Interrupts are still off, MIE and MEIE both, which tb_soc_lockstep relies on.
    "cold_start:",
    ("lui", "t0", 0x20000),
    ("lui", "t1", 0x12345),
    ("addi", "t1", "t1", 0x678),
    ("sw", "t1", 8, "t0"),
    ("addi", "t2", "zero", 0x5A),
    ("sb", "t2", 9, "t0"),
    ("lw", "t2", 8, "t0"),
    ("lui", "t1", 0x12346),            # 0x12345A78
    ("addi", "t1", "t1", -0x588),
    ("addi", "t0", "zero", ord("M")),
    ("beq", "t1", "t2", "ram_good"),
    ("addi", "t0", "zero", ord("m")),
    "ram_good:",
    ("sw", "t0", 0x400, "s0"),
    "wait_ram:",
    ("lw", "t1", 0x404, "s0"),
    ("andi", "t1", "t1", 1),
    ("bne", "t1", "zero", "wait_ram"),
    ("lw", "t2", 0x100, "s0"),
    ("addi", "t2", "t2", ord("0")),
    ("sw", "t2", 0x400, "s0"),
    "wait_count:",
    ("lw", "t1", 0x404, "s0"),
    ("andi", "t1", "t1", 1),
    ("bne", "t1", "zero", "wait_count"),
    ("addi", "t0", "zero", 8),         # MIE, from here on
    ("csrs", "mstatus", "t0"),

    # Send ID 0x123, DLC 2, data bytes 0xA5 and 0x5A
    ("addi", "t0", "zero", 0x123),
    ("sw", "t0", 0x300, "s0"),
    ("addi", "t0", "zero", 2),
    ("sw", "t0", 0x304, "s0"),
    ("lui", "t0", 0xA55A0),
    ("sw", "t0", 0x308, "s0"),

    # A byte store to TX_REQUEST must not start the frame: 'X' if it did
    ("sb", "t0", 0x314, "s0"),
    ("lw", "t1", 0x30C, "s0"),
    ("andi", "t1", "t1", 1),
    ("addi", "t2", "zero", ord("X")),
    ("bne", "t1", "zero", "report"),

    ("sw", "t0", 0x314, "s0"),         # any value requests the frame

    # Wait for CAN STATUS.busy to clear
    "wait_can:",
    ("lw", "t1", 0x30C, "s0"),
    ("andi", "t1", "t1", 1),
    ("bne", "t1", "zero", "wait_can"),

    # If CAN_ERROR arrived, report how many times as a digit
    ("beq", "s1", "zero", "no_irq"),
    ("addi", "t2", "s1", ord("0")),
    ("sw", "t2", 0x400, "s0"),
    "wait_i:",
    ("lw", "t1", 0x404, "s0"),
    ("andi", "t1", "t1", 1),
    ("bne", "t1", "zero", "wait_i"),
    "no_irq:",

    # Report 'K' if the error counter is zero, otherwise 'F'
    ("lw", "t1", 0x30C, "s0"),
    ("srli", "t1", "t1", 8),
    ("addi", "t2", "zero", ord("F")),
    ("bne", "t1", "zero", "report"),
    ("addi", "t2", "zero", ord("K")),
    "report:",
    ("sw", "t2", 0x400, "s0"),

    # Wait for UART STATUS.busy to clear, counting the reads in t0
    ("addi", "t0", "zero", 0),
    "wait_uart:",
    ("lw", "t1", 0x404, "s0"),
    ("addi", "t0", "t0", 1),
    ("andi", "t1", "t1", 1),
    ("bne", "t1", "zero", "wait_uart"),

    # A byte takes thousands of clocks, so 'B' means STATUS never showed busy
    ("addi", "t1", "zero", 1),
    ("addi", "t2", "zero", ord("B")),
    ("beq", "t0", "t1", "finish"),
    ("addi", "t2", "zero", ord("D")),
    "finish:",
    ("sw", "t2", 0x400, "s0"),

    # Kick twice, as soon as STATUS shows that the window is open, then say so and
    # stop. A kick takes a few watchdog clocks to reach STATUS, so wait for that.
    ("addi", "t0", "zero", 2),
    ("addi", "t2", "zero", WD_WINDOW_OPEN),
    "wait_window:",
    ("lw", "t1", 0x204, "s0"),
    ("andi", "t1", "t1", 0x1F),
    ("bne", "t1", "t2", "wait_window"),
    ("sw", "s4", 0x200, "s0"),
    "wait_kick:",
    ("lw", "t1", 0x204, "s0"),
    ("andi", "t1", "t1", 0x1F),
    ("beq", "t1", "t2", "wait_kick"),
    ("addi", "t0", "t0", -1),
    ("bne", "t0", "zero", "wait_window"),
    ("addi", "t2", "zero", ord("W")),
    ("sw", "t2", 0x400, "s0"),

    "done:",
    ("jal", "zero", "done"),

    # Bus probes (HSI section 8.1). Each load or store gets an ACK, or an ERR that
    # the trap handler counts in s5. a0 stays 'P' while data reads back right.
    # Then say 'A' plus the count, and the flag: 'L' and 'P' for 11 ERRs.
    "fabric:",
    ("addi", "a0", "zero", ord("P")),
    ("lui", "t0", 0x20000),            # t0 = first RAM word
    ("lui", "t1", 0x11111),
    ("addi", "t1", "t1", 0x111),       # t1 = 0x11111111
    ("sw", "t1", 0, "t0"),             # ACK
    ("lui", "t2", 0x20040),            # t2 = just past the RAM
    ("lw", "t3", 0, "t2"),             # ERR 1
    ("sw", "zero", 0, "t2"),           # ERR 2, and the first word keeps its value
    ("lw", "t3", -4, "t0"),            # ERR 3: just below the RAM
    ("sw", "t1", -4, "t2"),            # ACK: the last RAM word
    ("lw", "t3", -4, "t2"),            # ACK
    ("beq", "t3", "t1", "probe_last"),
    ("addi", "a0", "zero", ord("F")),
    "probe_last:",
    ("lw", "t3", 0, "s0"),             # ERR 4: the reserved comparator block
    ("lw", "t3", 0x110, "s0"),         # ERR 5: just past the ECC registers
    ("lw", "t3", 0x10C, "s0"),         # ACK: the last ECC register
    ("lw", "t3", 0x330, "s0"),         # ERR 6: just past the CAN registers
    ("lw", "t3", 0x40C, "s0"),         # ERR 7: just past the UART registers
    ("lw", "t3", 0x500, "s0"),         # ERR 8: past the last block
    ("lui", "t2", 0xC0000),
    ("lw", "t3", 0x400, "t2"),         # ERR 9: TX_DATA with bit 31 set
    ("sw", "t1", 0x314, "t2"),         # ERR 10: TX_REQUEST with bit 31 set, and no frame
    ("lui", "t2", 0x40001),
    ("sw", "t1", 0x400, "t2"),         # ERR 11: TX_DATA 4 KB up, and no byte
    ("sb", "t1", 0x401, "s0"),         # ACK: TX_DATA without byte 0, and no byte
    ("sh", "t1", 0x314, "s0"),         # ACK: halfword to TX_REQUEST, and no frame
    ("lw", "t3", 0, "t0"),             # ACK: the first word as stored
    ("beq", "t3", "t1", "probe_report"),
    ("addi", "a0", "zero", ord("F")),
    "probe_report:",
    ("addi", "t2", "s5", ord("A")),
    ("sw", "t2", 0x400, "s0"),
    ("sw", "a0", 0x400, "s0"),
    ("jal", "zero", "done"),
]


def i_type(imm, rs1, funct3, rd, opcode):
    return (imm & 0xFFF) << 20 | rs1 << 15 | funct3 << 12 | rd << 7 | opcode


def s_type(imm, rs2, rs1, funct3, opcode):
    return (imm >> 5 & 0x7F) << 25 | rs2 << 20 | rs1 << 15 | funct3 << 12 | (imm & 0x1F) << 7 | opcode


def b_type(imm, rs2, rs1, funct3, opcode):
    return ((imm >> 12 & 1) << 31 | (imm >> 5 & 0x3F) << 25 | rs2 << 20 | rs1 << 15 | funct3 << 12
            | (imm >> 1 & 0xF) << 8 | (imm >> 11 & 1) << 7 | opcode)


def j_type(imm, rd, opcode):
    return ((imm >> 20 & 1) << 31 | (imm >> 1 & 0x3FF) << 21 | (imm >> 11 & 1) << 20
            | (imm >> 12 & 0xFF) << 12 | rd << 7 | opcode)


def encode(ins, pc, labels):
    op, *args = ins
    reg = REGISTERS
    if op == "mret":
        return 0x30200073
    if op == "csrr":
        return i_type(CSRS[args[1]], 0, 0b010, reg[args[0]], 0x73)
    if op == "csrw":
        return i_type(CSRS[args[0]], reg[args[1]], 0b001, 0, 0x73)
    if op == "csrs":
        return i_type(CSRS[args[0]], reg[args[1]], 0b010, 0, 0x73)
    if op == "lui":
        return args[1] << 12 | reg[args[0]] << 7 | 0x37
    if op == "addi":
        return i_type(args[2], reg[args[1]], 0b000, reg[args[0]], 0x13)
    if op == "andi":
        return i_type(args[2], reg[args[1]], 0b111, reg[args[0]], 0x13)
    if op == "srli":
        return i_type(args[2], reg[args[1]], 0b101, reg[args[0]], 0x13)
    if op == "lw":
        return i_type(args[1], reg[args[2]], 0b010, reg[args[0]], 0x03)
    if op == "sb":
        return s_type(args[1], reg[args[0]], reg[args[2]], 0b000, 0x23)
    if op == "sh":
        return s_type(args[1], reg[args[0]], reg[args[2]], 0b001, 0x23)
    if op == "sw":
        return s_type(args[1], reg[args[0]], reg[args[2]], 0b010, 0x23)
    if op == "beq":
        return b_type(labels[args[2]] - pc, reg[args[1]], reg[args[0]], 0b000, 0x63)
    if op == "bne":
        return b_type(labels[args[2]] - pc, reg[args[1]], reg[args[0]], 0b001, 0x63)
    if op == "jal":
        return j_type(labels[args[1]] - pc, reg[args[0]], 0x6F)
    raise ValueError(op)


def assemble():
    labels, pc = {}, 0
    for item in PROGRAM:
        if isinstance(item, str):
            labels[item.rstrip(":")] = pc
        else:
            pc += 4

    assert labels["trap"] == TRAP_ADDRESS

    words, pc = [], 0
    for item in PROGRAM:
        if not isinstance(item, str):
            words.append((encode(item, pc, labels), " ".join(str(a) for a in item)))
            pc += 4
    return words


def main():
    words = assemble()
    lines = [f'x"{word:08x}", -- {text}' for word, text in words]
    OUTPUT.parent.mkdir(exist_ok=True)
    OUTPUT.write_text(
        "-- Generated by sim/scripts/soc_firmware.py. Takes the place of NEORV32's\n"
        "-- default image in simulation, and is used by boot mode 2 only.\n\n"
        "library ieee;\nuse ieee.std_logic_1164.all;\n\n"
        "package neorv32_imem_image is\n\n"
        f"type rom_t is array (0 to {ROM_WORDS - 1}) of std_ulogic_vector(31 downto 0);\n"
        f"constant image_size_c : natural := {ROM_WORDS * 4};\n"
        "constant image_data_c : rom_t := (\n" + "\n".join(lines) + "\n"
        'others => x"00000000"\n);\n\nend neorv32_imem_image;\n',
        newline="\n",
    )
    print(f"{len(words)} instructions written to {OUTPUT}")


if __name__ == "__main__":
    main()
