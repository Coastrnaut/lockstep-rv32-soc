#!/usr/bin/env python3
"""Reference model of a CAN 2.0 base-format data frame on the wire.

Written from the Bosch CAN 2.0 specification, separately from the RTL, so that
the benches have bits the RTL had no part in producing. The golden wire strings
in sim/tb/tb_can.vhd come from this script, and it writes the frames for
tb_can_receive as sim/generated/can_rx_frames_pkg.vhd:

    python sim/scripts/can_frame_model.py

Bits are ints, 0 = dominant, 1 = recessive, in the order they go on the wire.
"""
from pathlib import Path

RX_PACKAGE = Path(__file__).parent.parent / "generated" / "can_rx_frames_pkg.vhd"

CRC15_POLY = 0x4599
STUFF_RUN = 5
TAIL_BITS = 3 + 7 + 3  # CRC delimiter, ACK slot, ACK delimiter; EOF; intermission

GOLDEN_FRAMES = [
    ("typical", 0x123, 2, 0xA55A),
    ("mostly dominant", 0x000, 8, 0x0000),
    ("mostly recessive", 0x7EF, 8, 0xFFFF),  # 0x7F0 and above are not legal CAN 2.0 IDs
    ("alternating", 0x555, 8, 0xAAAA),
    ("no data", 0x2AA, 0, 0x0000),
    ("dlc above 8", 0x123, 15, 0x1234),
    ("stuff bit after a dominant CRC tail", 0x009, 0, 0x0000),
    ("stuff bit after a recessive CRC tail", 0x017, 0, 0x0000),
    ("rival that beats 0x123", 0x122, 2, 0xA55A),
    ("rival that loses to 0x123", 0x124, 2, 0xA55A),
]


# Frames for the receiver to take in: name, identifier, extended, remote, DLC, data
RX_FRAMES = [
    ("base, no data", 0x2AA, False, False, 0, 0),
    ("base, 1 byte", 0x123, False, False, 1, 0xA500000000000000),
    ("base, 2 bytes", 0x123, False, False, 2, 0xA55A000000000000),
    ("base, 3 bytes", 0x7EF, False, False, 3, 0x0102030000000000),
    ("base, 4 bytes", 0x001, False, False, 4, 0xFFFFFFFF00000000),
    ("base, 5 bytes", 0x400, False, False, 5, 0x0000000000000000),
    ("base, 6 bytes", 0x555, False, False, 6, 0xAAAAAAAAAAAA0000),
    ("base, 7 bytes", 0x2AA, False, False, 7, 0x5555555555555500),
    ("base, 8 bytes", 0x123, False, False, 8, 0x1122334455667788),
    ("base, most stuffing", 0x000, False, False, 8, 0x0000000000000000),
    ("base, recessive stuffing", 0x7EF, False, False, 8, 0xFFFFFFFFFFFFFFFF),
    ("base, DLC above 8", 0x123, False, False, 15, 0x1122334455667788),
    ("stuff bit after a dominant CRC tail", 0x009, False, False, 0, 0),
    ("stuff bit after a recessive CRC tail", 0x017, False, False, 0, 0),
    ("remote, no data asked for", 0x123, False, True, 0, 0),
    ("remote, 8 bytes asked for", 0x456, False, True, 8, 0),
    ("extended, no data", 0x12345678, True, False, 0, 0),
    ("extended, 8 bytes", 0x1FFFFFFF, True, False, 8, 0x1122334455667788),
    ("extended, most stuffing", 0x00000000, True, False, 8, 0x0000000000000000),
    ("extended, remote", 0x0ABCDEF0, True, True, 4, 0),
]


def crc15(bits):
    """CRC-15/CAN, using the shift-register sequence from the Bosch spec."""
    crc = 0
    for bit in bits:
        crc_next = bit ^ (crc >> 14)
        crc = (crc << 1) & 0x7FFF
        if crc_next:
            crc ^= CRC15_POLY
    return crc


def to_bits(value, width):
    return [(value >> i) & 1 for i in reversed(range(width))]


def data_bytes(dlc, payload):
    """Bytes tb_can sends for most frames: the low 8 * n bits of payload repeated 4 times."""
    count = min(dlc, 8)
    repeated = int(f"{payload:04x}" * 4, 16)
    return to_bits(repeated, 64)[64 - 8 * count:]


def stuff(bits):
    """Add a complementary bit after 5 identical bits, including after the last."""
    wire, run, last = [], 0, None
    for bit in bits:
        if run == STUFF_RUN:
            last = 1 - last
            wire.append(last)
            run = 1
        wire.append(bit)
        run = run + 1 if bit == last else 1
        last = bit
    if run == STUFF_RUN:
        wire.append(1 - last)
    return wire


def frame_bits(can_id, dlc, data):
    """Return (wire bits, crc) for one data frame carrying the given data bits."""
    header = [0] + to_bits(can_id, 11) + [0, 0, 0] + to_bits(dlc, 4)  # SOF, ID, RTR, IDE, r0, DLC
    covered = header + data
    crc = crc15(covered)
    return stuff(covered + to_bits(crc, 15)) + [1] * TAIL_BITS, crc


def header_bits(can_id, extended, remote, dlc):
    """SOF to the end of the DLC, for a base or an extended frame."""
    rtr = 1 if remote else 0
    if extended:
        return ([0] + to_bits(can_id >> 18, 11) + [1, 1] + to_bits(can_id & 0x3FFFF, 18)
                + [rtr, 0, 0] + to_bits(dlc, 4))
    return [0] + to_bits(can_id, 11) + [rtr, 0, 0] + to_bits(dlc, 4)


def payload_bits(remote, dlc, data):
    return [] if remote else to_bits(data, 64)[:8 * min(dlc, 8)]


def rx_frame_bits(can_id, extended, remote, dlc, data):
    """Return (stuffed bits up to the end of the CRC, tail) for one frame."""
    covered = header_bits(can_id, extended, remote, dlc) + payload_bits(remote, dlc, data)
    return stuff(covered + to_bits(crc15(covered), 15)), [1] * TAIL_BITS


def bad_frames():
    """Frames that a receiver must reject, and where its error flag must start.

    Each is (name, wire bits, wire bit that starts the error flag, wire bit that
    the receiver acknowledges in), counting wire bits from 0. The flag comes in the
    bit after the error, or after the ACK delimiter for a CRC error. The last is
    not an error at all, so it has no flag.
    """
    good, tail = rx_frame_bits(0x123, False, False, 2, 0xA55A000000000000)
    end = len(good)                    # CRC delimiter, then ACK slot, ACK delimiter, EOF
    frames = []

    # Six identical bits where the fifth should have been followed by a stuff bit
    dominant, _ = rx_frame_bits(0x000, False, False, 0, 0)
    assert dominant[:6] == [0, 0, 0, 0, 0, 1]
    frames.append(("six dominant bits", dominant[:5] + [0], 6, None))
    recessive, _ = rx_frame_bits(0x7C0, False, False, 0, 0)
    assert recessive[:7] == [0, 1, 1, 1, 1, 1, 0]
    frames.append(("six recessive bits", recessive[:6] + [1], 7, None))

    # One flipped data bit, with the stuffing right and the CRC of the good data
    covered = header_bits(0x123, False, False, 2) + payload_bits(False, 2, 0xA55A000000000000)
    crc = to_bits(crc15(covered), 15)
    covered[20] ^= 1
    flipped = stuff(covered + crc)
    frames.append(("CRC error", flipped + tail, len(flipped) + 3, None))

    frames.append(("CRC delimiter dominant", good + [0], end + 1, None))
    frames.append(("ACK delimiter dominant", good + [1, 1, 0], end + 3, end + 1))
    for bit in range(6):
        frames.append((f"EOF bit {bit + 1} dominant", good + [1, 1, 1] + [1] * bit + [0], end + 3 + bit + 1, end + 1))
    frames.append(("EOF bit 7 dominant", good + [1, 1, 1] + [1] * 6 + [0], None, end + 1))
    return frames


def vhdl_bits(bits):
    return "".join(str(b) for b in bits)


def write_rx_package():
    """Write the frames for tb_can_receive."""
    wires = [rx_frame_bits(*frame[1:]) for frame in RX_FRAMES]
    longest = max(len(body) + len(tail) for body, tail in wires)
    longest = max(longest, max(len(bits) for _, bits, _, _ in bad_frames()))
    longest += 20                      # So that a bench can go on past the end of a wire

    lines = [
        "-- Generated by sim/scripts/can_frame_model.py, which has no part in the RTL.",
        "-- Regenerate it with: python sim/scripts/can_frame_model.py",
        "",
        "library ieee;",
        "  use ieee.std_logic_1164.all;",
        "",
        "package can_rx_frames_pkg is",
        "",
        f"  constant c_wire_length : positive := {longest};",
        "",
        "  subtype t_wire is string(1 to c_wire_length);",
        "",
        "  type t_rx_vector is record",
        "    id       : std_logic_vector(28 downto 0);",
        "    extended : std_logic;",
        "    remote   : std_logic;",
        "    dlc      : std_logic_vector(3 downto 0);",
        "    data     : std_logic_vector(63 downto 0);",
        "    length   : positive;                      -- Wire bits, to the end of the intermission",
        "    ack_slot : positive;                      -- From 1",
        "    wire     : t_wire;",
        "  end record t_rx_vector;",
        "",
        "  type t_rx_vectors is array (natural range <>) of t_rx_vector;",
        "",
        "  type t_bad_vector is record",
        "    length  : positive;",
        "    flag_at : natural;                        -- From 1, and 0 for no error flag",
        "    ack_at  : natural;                        -- From 1, and 0 for no ACK",
        "    wire    : t_wire;",
        "  end record t_bad_vector;",
        "",
        "  type t_bad_vectors is array (natural range <>) of t_bad_vector;",
        "",
        "  constant c_rx_vectors : t_rx_vectors :=",
        "  (",
    ]

    entries = []
    for (name, can_id, extended, remote, dlc, data), (body, tail) in zip(RX_FRAMES, wires):
        bits = body + tail
        data_shown = 0 if remote else data >> (64 - 8 * min(dlc, 8)) << (64 - 8 * min(dlc, 8)) if dlc else 0
        entries.append(
            f"    -- {name}\n"
            f"    (id => \"{to_text(can_id, 29)}\", extended => '{int(extended)}', remote => '{int(remote)}',\n"
            f"     dlc => \"{to_text(dlc, 4)}\", data => x\"{data_shown:016X}\",\n"
            f"     length => {len(bits)}, ack_slot => {len(body) + 2},\n"
            f"     wire => \"{vhdl_bits(bits).ljust(longest)}\")"
        )
    lines.append(",\n".join(entries))
    lines += ["  );", "", "  constant c_bad_vectors : t_bad_vectors :=", "  ("]

    entries = []
    for name, bits, flag, ack in bad_frames():
        entries.append(
            f"    -- {name}\n"
            f"    (length => {len(bits)}, flag_at => {0 if flag is None else flag + 1}, "
            f"ack_at => {0 if ack is None else ack + 1},\n"
            f"     wire => \"{vhdl_bits(bits).ljust(longest)}\")"
        )
    lines.append(",\n".join(entries))
    lines += ["  );", "", "end package can_rx_frames_pkg;", ""]
    RX_PACKAGE.parent.mkdir(exist_ok=True)
    RX_PACKAGE.write_text("\n".join(lines), newline="\n")
    print(f"{len(RX_FRAMES)} frames and {len(bad_frames())} bad frames written to {RX_PACKAGE}")


def to_text(value, width):
    return "".join(str(bit) for bit in to_bits(value, width))


def frame(can_id, dlc, payload):
    """Return (wire bits, crc) for a frame carrying a repeated 16-bit payload."""
    return frame_bits(can_id, dlc, data_bytes(dlc, payload))


def wire_string(bits):
    return "".join(str(b) for b in bits)


def main():
    check = crc15([b for byte in b"123456789" for b in to_bits(byte, 8)])
    assert check == 0x059E, f"CRC-15/CAN check value mismatch: {check:#06x}"
    print(f"CRC-15/CAN check value: {check:#06x}")

    for label, can_id, dlc, payload in GOLDEN_FRAMES:
        bits, crc = frame(can_id, dlc, payload)
        print(f"{label}: id={can_id:#05x} dlc={dlc} payload={payload:#06x} crc={crc:#06x} bits={len(bits)}")
        print(f"  {wire_string(bits)}")

    bits, crc = frame_bits(0x123, 8, to_bits(0x1122334455667788, 64))
    print(f"8 different bytes: id=0x123 dlc=8 data=0x1122334455667788 crc={crc:#06x} bits={len(bits)}")
    print(f"  {wire_string(bits)}")

    write_rx_package()


if __name__ == "__main__":
    main()
