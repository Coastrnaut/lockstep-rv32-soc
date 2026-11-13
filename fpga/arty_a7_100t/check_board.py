#!/usr/bin/env python3
"""Check the Arty A7 board files without Vivado (roadmap R3.1 and R3.3).

    python fpga/arty_a7_100t/check_board.py

1. GHDL analyses the board wrapper with the board image and synthesises it,
   with the Xilinx clocking primitives as black boxes, which catches errors in
   the wrapper before a Vivado run.
2. GHDL runs tb_board_firmware: the board image on the SoC must print "LS0"
   and then a dot for each watchdog kick, with no fault.

Uses GHDL as sim/run.py finds it. Work files go to fpga/arty_a7_100t/build/ghdl.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORK = HERE / "build" / "ghdl"
WINDOWS_GHDL = Path(r"C:\GIT\ghdl-mcode-6.0.0-ucrt64\bin\ghdl.exe")

# Analysis follows this order, so a block comes after any it instantiates
WRAPPERS = ("automotive_can_controller", "ecc_data_ram", "watchdog_supervisor")


def find_ghdl():
    explicit = os.environ.get("VUNIT_GHDL_PATH")
    if explicit:
        for name in ("ghdl", "ghdl.exe"):
            if (Path(explicit) / name).is_file():
                return str(Path(explicit) / name)
    if os.name == "nt" and WINDOWS_GHDL.is_file():
        return str(WINDOWS_GHDL)
    return shutil.which("ghdl")


def run(cmd, label):
    r = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True)
    if r.returncode != 0:
        print((r.stdout + r.stderr)[-4000:])
        sys.exit(f"FAILED: {label}")
    return r.stdout + r.stderr


def posix(path):
    return str(path).replace("\\", "/")


def main():
    ghdl = find_ghdl()
    if not ghdl:
        sys.exit("GHDL not found")
    shutil.rmtree(WORK, ignore_errors=True)
    WORK.mkdir(parents=True)
    analyse = [ghdl, "-a", "--std=08"]

    run(analyse + ["--work=unisim", posix(HERE / "ghdl" / "unisim_vcomponents.vhd")], "UNISIM stand-in")

    neorv32 = ROOT / "rtl" / "core" / "neorv32"
    core = []
    for line in (neorv32 / "rtl" / "file_list_core.f").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("--") or line.endswith("neorv32_imem_image.vhd"):
            continue
        core.append(posix(line.replace("$NEORV32_HOME", posix(neorv32))))
    run(analyse + ["--work=neorv32", posix(HERE / "board_imem_image.vhd")] + core, "NEORV32 with the board image")

    first_party = [ROOT / "config" / "package_soc_types.vhd"]
    for folder in ("safety_blocks", "peripherals"):
        first_party += sorted((ROOT / "rtl" / folder).glob("*.vhd"), key=lambda f: (f.stem in WRAPPERS, f.stem))
    first_party.append(ROOT / "rtl" / "top_automotive_soc.vhd")
    run(analyse + ["--work=lockstep"] + [posix(f) for f in first_party], "SoC RTL")

    run(analyse + [posix(HERE / "arty_a7_top.vhd")], "board wrapper")
    run([ghdl, "--synth", "--std=08", "arty_a7_top"], "board wrapper synthesis")
    print("ok: the board wrapper analyses and synthesises, with the clocking primitives as black boxes")

    run(analyse + [posix(HERE / "ghdl" / "tb_board_firmware.vhd")], "board firmware bench")
    out = run([ghdl, "--elab-run", "--std=08", "tb_board_firmware", "--stop-time=30ms"], "board firmware run")
    passed = [line for line in out.splitlines() if "BOARD FIRMWARE PASS" in line]
    if not passed:
        print(out[-3000:])
        sys.exit("FAILED: the board image did not print what it should")
    print("ok: " + passed[0].split("BOARD FIRMWARE ", 1)[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
