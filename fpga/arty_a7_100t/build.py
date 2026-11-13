#!/usr/bin/env python3
"""Build the Arty A7-100T bitstream with Vivado, and record what it produced.

    python fpga/arty_a7_100t/build.py [OUT_DIR] [--ram-addr-bits N]

OUT_DIR defaults to fpga/arty_a7_100t/build. --ram-addr-bits picks the RAM
profile, 4 to 15 bits of 64-bit words; 15, the default, is the full 256 KB of
HSI section 5, and 12 is 32 KB. The manifest records the profile with its
utilisation and timing, so each profile's cost is on record.

Runs build.tcl in Vivado batch mode, which stops if the safety structure does
not survive synthesis or implementation, or timing is missed. Then writes
manifest.json: the Vivado version, the part, the commit, timing slack,
utilisation, and the bitstream's SHA-256.

Vivado comes from VIVADO (the executable), then PATH, then the default Windows
install. The device must be installed: Vivado's get_parts has to list
xc7a100tcsg324-1.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PART = "xc7a100tcsg324-1"
# The IMEM images sw/build.py writes, by program
IMAGES = {"board": HERE / "board_imem_image.vhd", "hello": ROOT / "sw" / "hello" / "hello_imem_image.vhd"}
WINDOWS_VIVADO = Path(r"C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat")


def find_vivado():
    if os.environ.get("VIVADO"):
        return os.environ["VIVADO"]
    found = shutil.which("vivado")
    if found:
        return found
    if os.name == "nt" and WINDOWS_VIVADO.is_file():
        return str(WINDOWS_VIVADO)
    sys.exit("Vivado not found: set VIVADO or put vivado on PATH")


def utilisation(report):
    """The slice LUT, register, block RAM and DSP lines of a utilisation report."""
    rows = {}
    for line in report.read_text(errors="replace").splitlines():
        m = re.match(r"\|\s*(Slice LUTs|Slice Registers|Block RAM Tile|DSPs)\s*\|\s*([\d.]+)\s*\|.*?\|\s*([\d.]+)\s*\|\s*([\d.<]+)\s*\|", line)
        if m and m.group(1) not in rows:
            rows[m.group(1)] = {"used": m.group(2), "available": m.group(3), "percent": m.group(4)}
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out", nargs="?", default=str(HERE / "build"))
    parser.add_argument("--ram-addr-bits", type=int, default=15, choices=range(4, 16), metavar="4..15")
    parser.add_argument("--program", choices=("board", "hello"), default="board",
                        help="the program both cores boot: the board program (default) or hello, world")
    args = parser.parse_args()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    vivado = find_vivado()
    cmd = [vivado, "-mode", "batch", "-nojournal", "-log", str(out / "vivado.log"),
           "-source", str(HERE / "build.tcl"), "-tclargs", str(ROOT), str(out), str(args.ram_addr_bits),
           str(IMAGES[args.program])]
    print(" ".join(cmd), flush=True)
    r = subprocess.run(cmd, capture_output=True, text=True)
    log = r.stdout + r.stderr
    (out / "build_stdout.log").write_text(log, encoding="utf-8")
    if any(s in log for s in ("Could not get a valid part", "No part matched", "Invalid part specified")):
        licence = re.search(r"INFO: \[Common 17-\d+\] (A valid .*license.*)", log)
        sys.exit(f"Vivado lists no {PART}, so it cannot build for the board. The Artix-7 device files "
                 f"may be installed and still not offered: Vivado offers only the parts its licence "
                 f"covers" + (f" (it reported: {licence.group(1).strip()})" if licence else "") +
                 ". Check get_parts in the Vivado Tcl console, and the licence manager.")
    # Vivado echoes the Tcl source with a leading '#', so only lines that start with the
    # message are results
    checks = re.findall(r"^BUILD CHECK (OK|FAILED): (.*)$", log, re.M)
    for status, message in checks:
        print(f"[{status}] {message}")
    if r.returncode != 0 or "BUILD DONE" not in log:
        sys.exit(f"Vivado build failed (exit {r.returncode}); see {out / 'vivado.log'}")

    bit = out / "arty_a7_lockstep.bit"
    timing = re.search(r"TIMING WNS=(\S+) WHS=(\S+)", log)
    version = subprocess.run([vivado, "-version"], capture_output=True, text=True).stdout.splitlines()
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    manifest = {
        "commit": commit,
        "vivado": version[0] if version else None,
        "part": PART,
        "ram_profile": {"addr_bits": args.ram_addr_bits, "bytes": 8 << args.ram_addr_bits},
        "program": args.program,
        "wns_ns": timing.group(1) if timing else None,
        "whs_ns": timing.group(2) if timing else None,
        "utilisation": utilisation(out / "utilization.txt"),
        "checks": [message for status, message in checks if status == "OK"],
        "bitstream": bit.name,
        "bitstream_sha256": hashlib.sha256(bit.read_bytes()).hexdigest(),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
