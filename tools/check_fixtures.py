#!/usr/bin/env python3
"""Do the checked-in generated files still match their generators?

Runs each generator below on a copy of the tree and compares their output with the checked-in files, ignoring
line endings only. Exit status 1 names each file that drifted. The working tree
is left alone.

    python tools/check_fixtures.py
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Each generator and what it writes. A generator that edits a file in place,
# like register_map.py with the package, gets that file copied in first. The
# board image needs the pinned RISC-V compiler, so sw/build.py --check checks
# it on its own (in CI, in the board job).
FIXTURES = {
    "sim/scripts/soc_firmware.py": ["sim/firmware/neorv32_imem_image.vhd"],
    "sim/scripts/can_frame_model.py": ["sim/generated/can_rx_frames_pkg.vhd"],
    "tools/register_map.py": ["rtl/pkg/package_soc_types.vhd", "sw/include/lockstep_soc_regs.h",
                                    "docs/safety/register_map.md", "sim/generated/register_map_pkg.vhd"],
    "tools/vsg_config.py": ["sim/vsg_config.yaml", "sim/vsg_testbench.yaml"],
}


def normalise(path):
    return path.read_bytes().replace(b"\r\n", b"\n")


def main():
    drift = []
    with tempfile.TemporaryDirectory(prefix="lockstep_fixtures_") as tmp:
        copy = Path(tmp)
        for script, outputs in FIXTURES.items():
            (copy / script).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / script, copy / script)
            for output in outputs:
                (copy / output).parent.mkdir(parents=True, exist_ok=True)
                if output.endswith(".vhd") and (ROOT / output).is_file() and "rtl/pkg/" in output:
                    shutil.copy2(ROOT / output, copy / output)
        for script, outputs in FIXTURES.items():
            r = subprocess.run([sys.executable, str(copy / script)], cwd=copy, capture_output=True, text=True)
            if r.returncode != 0:
                print(r.stdout + r.stderr)
                drift.append(f"{script} failed")
                continue
            for output in outputs:
                if not (ROOT / output).is_file() or normalise(copy / output) != normalise(ROOT / output):
                    drift.append(f"{output} differs from what {script} generates")
                else:
                    print(f"ok: {output}")
    for item in drift:
        print(f"DRIFT: {item}")
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
