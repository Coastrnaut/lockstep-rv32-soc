#!/usr/bin/env python3
"""Do the checked-in generated files still match their generators?

Runs sim/scripts/soc_firmware.py and sim/scripts/can_frame_model.py on a copy
of the tree and compares their output with the checked-in files, ignoring
line endings only. Exit status 1 names each file that drifted. The working tree
is left alone.

    python sim/scripts/check_fixtures.py
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

FIXTURES = {
    "sim/scripts/soc_firmware.py": "sim/firmware/neorv32_imem_image.vhd",
    "sim/scripts/can_frame_model.py": "sim/generated/can_rx_frames_pkg.vhd",
}


def normalise(path):
    return path.read_bytes().replace(b"\r\n", b"\n")


def main():
    drift = []
    with tempfile.TemporaryDirectory(prefix="lockstep_fixtures_") as tmp:
        copy = Path(tmp)
        for script, output in FIXTURES.items():
            (copy / script).parent.mkdir(parents=True, exist_ok=True)
            (copy / output).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / script, copy / script)
        for script, output in FIXTURES.items():
            r = subprocess.run([sys.executable, str(copy / script)], cwd=copy, capture_output=True, text=True)
            if r.returncode != 0:
                print(r.stdout + r.stderr)
                drift.append(f"{script} failed")
                continue
            if normalise(copy / output) != normalise(ROOT / output):
                drift.append(f"{output} differs from what {script} generates")
            else:
                print(f"ok: {output}")
    for item in drift:
        print(f"DRIFT: {item}")
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
