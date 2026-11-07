#!/usr/bin/env python3
"""Assemble the RV32I test program for the SoC testbenches into an IMEM image.

The cores run this from reset. It uses the peripherals the way real software
would, and reports what it reads back over the UART, so the testbenches can tell
that stores and loads work on both lockstep cores. Regenerate the image with:

    python sim/scripts/soc_firmware.py
"""
from pathlib import Path

OUTPUT = Path(__file__).parent.parent / "firmware" / "neorv32_imem_image.vhd"
REGISTERS = {"zero": 0, "t0": 5, "t1": 6, "t2": 7, "s0": 8, "s1": 9, "s2": 18, "s3": 19, "s4": 20, "t3": 28}
CSRS = {"mstatus": 0x300, "mie": 0x304, "mtvec": 0x305, "mcause": 0x342}
ROM_WORDS = 256
TRAP_ADDRESS = 4
WD_WINDOW_OPEN = 20                    # Watchdog STATUS value once the counter is past 40960

PROGRAM = [
    ("jal", "zero", "main"),

    # Interrupts: count them in s1 (CAN_ERROR) and s2 (UART_ERROR), and clear them
    "trap:",
    ("csrr", "t3", "mcause"),
    ("andi", "t3", "t3", 4),           # 7 = MTI has this bit, 3 = MSI does not
    ("bne", "t3", "zero", "trap_uart"),
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
    ("lui", "s4", 0xE),                # s4 = watchdog key, 0xDEAD
    ("addi", "s4", "s4", -339),
    ("addi", "t0", "zero", TRAP_ADDRESS),
    ("csrw", "mtvec", "t0"),
    ("addi", "t0", "zero", 0x88),      # MSI and MTI
    ("csrw", "mie", "t0"),
    ("addi", "t0", "zero", 8),
    ("csrs", "mstatus", "t0"),

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
    # the watchdog to time out. tb_soc_watchdog follows this round.
    ("beq", "s3", "zero", "cold_start"),
    ("addi", "t1", "zero", 2),
    ("bne", "s3", "t1", "done"),
    ("sw", "s4", 0x200, "s0"),
    ("jal", "zero", "done"),

    # Send ID 0x123, DLC 2, data bytes 0xA5 and 0x5A
    "cold_start:",
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
