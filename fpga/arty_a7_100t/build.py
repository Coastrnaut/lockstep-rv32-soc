#!/usr/bin/env python3
"""Build the Arty A7-100T bitstream with Vivado, and record what it produced.

    python fpga/arty_a7_100t/build.py [OUT_DIR]       default fpga/arty_a7_100t/build

Runs build.tcl in Vivado batch mode, which stops if the safety structure does
not survive synthesis or implementation, or timing is missed. Then writes
manifest.json: the Vivado version, the part, the commit, timing slack,
utilisation, and the bitstream's SHA-256.

Vivado comes from VIVADO (the executable), then PATH, then the default Windows
install. The device must be installed: Vivado's get_parts has to list
xc7a100tcsg324-1.
"""
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
    out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HERE / "build"
    out.mkdir(parents=True, exist_ok=True)
    vivado = find_vivado()
    cmd = [vivado, "-mode", "batch", "-nojournal", "-log", str(out / "vivado.log"),
           "-source", str(HERE / "build.tcl"), "-tclargs", str(ROOT), str(out)]
    print(" ".join(cmd), flush=True)
    r = subprocess.run(cmd, capture_output=True, text=True)
    log = r.stdout + r.stderr
    (out / "build_stdout.log").write_text(log, encoding="utf-8")
    if "Could not get a valid part" in log or "No part matched" in log:
        sys.exit(f"Vivado has no {PART}: add the Artix-7 devices with the AMD installer")
    checks = re.findall(r"BUILD CHECK (OK|FAILED): (.*)", log)
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
