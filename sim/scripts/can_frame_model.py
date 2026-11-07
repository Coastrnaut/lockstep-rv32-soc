#!/usr/bin/env python3
"""Reference model of a CAN 2.0 base-format data frame on the wire.

Written from the Bosch CAN 2.0 specification, separately from the RTL, so that
tb_can has expected bits the RTL had no part in producing. The golden wire
strings in sim/testbenches/tb_can.vhd come from this script:

    python sim/scripts/can_frame_model.py

Bits are ints, 0 = dominant, 1 = recessive, in the order they go on the wire.
"""

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


if __name__ == "__main__":
    main()
