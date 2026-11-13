#!/usr/bin/env python3
"""Build the board program with the pinned compiler (roadmap R3.3).

sw/board/start.S and sw/board/main.c, linked by sw/board/link.ld, become
sw/build/board.elf with its map file, and then the Arty A7-100T build's IMEM
image, fpga/arty_a7_100t/board_imem_image.vhd, one commented word per line.

The compiler is pinned: xPack GNU RISC-V Embedded GCC 15.2.0-1. Another
version may produce other code, so the image is only written, or checked,
with that one. It is found from:

  RISCV_PREFIX  the tools' prefix, e.g. /opt/xpack/bin/riscv-none-elf-
  PATH          riscv-none-elf-gcc
  WSL           on Windows, ~/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin in
                the default WSL distribution (RISCV_WSL_DISTRO picks another)

    python sw/build.py           build, and write the image
    python sw/build.py --check   build, and fail if the image differs
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SW = ROOT / "sw"
SOURCES = [SW / "board" / "start.S", SW / "board" / "main.c"]
LINKER_SCRIPT = SW / "board" / "link.ld"
IMAGE = ROOT / "fpga" / "arty_a7_100t" / "board_imem_image.vhd"

PINNED = "xPack GNU RISC-V Embedded GCC"
PINNED_VERSION = "15.2.0"
PINNED_RELEASE = "15.2.0-1"
WSL_TOOLS = f"~/tools/xpack-riscv-none-elf-gcc-{PINNED_RELEASE}/bin/riscv-none-elf-"

CFLAGS = ["-march=rv32i_zicsr", "-mabi=ilp32", "-Os", "-ffreestanding", "-fno-builtin", "-nostdlib",
          "-msmall-data-limit=0", "-mno-relax", "-Wall", "-Wextra", "-Werror", "-g0",
          "-ffunction-sections", "-fdata-sections"]

sys.path.insert(0, str(ROOT / "sim" / "scripts"))
import soc_firmware as fw  # noqa: E402 - needs the path above


class Toolchain:
    """Runs the compiler's tools, natively or through WSL."""

    def __init__(self):
        self.wsl = None
        prefix = os.environ.get("RISCV_PREFIX")
        if not prefix and shutil.which("riscv-none-elf-gcc"):
            prefix = str(Path(shutil.which("riscv-none-elf-gcc")).parent / "riscv-none-elf-")
        if not prefix and os.name == "nt" and shutil.which("wsl"):
            for wsl in self.wsl_distributions():
                found = subprocess.run(wsl + ["-e", "sh", "-c", f"ls {WSL_TOOLS}gcc"],
                                       capture_output=True, text=True)
                if found.returncode == 0 and found.stdout.strip():
                    prefix = found.stdout.strip()[:-len("gcc")]
                    self.wsl = wsl
                    break
        if not prefix:
            raise SystemExit(f"ERROR: {PINNED} {PINNED_RELEASE} not found: set RISCV_PREFIX, "
                             "or put riscv-none-elf-gcc on PATH")
        self.prefix = prefix

    @staticmethod
    def wsl_distributions():
        """wsl commands to try: RISCV_WSL_DISTRO, else the default, then each other one."""
        if os.environ.get("RISCV_WSL_DISTRO"):
            return [["wsl", "-d", os.environ["RISCV_WSL_DISTRO"]]]
        listing = subprocess.run(["wsl", "-l", "-q"], capture_output=True)
        names = listing.stdout.decode("utf-16-le", errors="ignore").replace("\0", "").split()
        return [["wsl"]] + [["wsl", "-d", name] for name in names]

    def path(self, p):
        """A path as the tools see it."""
        p = Path(p).resolve()
        if self.wsl:
            return "/mnt/" + p.drive[0].lower() + p.as_posix()[2:]
        return str(p)

    def run(self, tool, *args):
        cmd = [self.prefix + tool, *args]
        if self.wsl:
            cmd = self.wsl + ["-e"] + cmd
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"ERROR: {tool} failed:\n{result.stdout}{result.stderr}")
        return result.stdout

    def version(self):
        first = self.run("gcc", "--version").splitlines()[0]
        if PINNED not in first or f" {PINNED_VERSION}" not in first:
            raise SystemExit(f"ERROR: the image needs {PINNED} {PINNED_RELEASE}, found: {first}")
        return first


def build(tools, out):
    """Compile and link into out; returns the image's words with their text."""
    out.mkdir(parents=True, exist_ok=True)
    objects = []
    for src in SOURCES:
        obj = out / (src.stem + ".o")
        tools.run("gcc", *CFLAGS, "-I" + tools.path(SW / "include"), "-c", tools.path(src), "-o", tools.path(obj))
        objects.append(tools.path(obj))
    elf = out / "board.elf"
    tools.run("gcc", *CFLAGS, "-T", tools.path(LINKER_SCRIPT), "-Wl,--gc-sections",
              "-Wl,-Map=" + tools.path(out / "board.map"), *objects, "-o", tools.path(elf))
    tools.run("objcopy", "-O", "binary", "--only-section=.text", tools.path(elf), tools.path(out / "board.bin"))
    binary = (out / "board.bin").read_bytes()
    binary += b"\0" * (-len(binary) % 4)

    # One comment per word: the instruction, from the disassembler
    text = {}
    for line in tools.run("objdump", "-d", "-M", "no-aliases", tools.path(elf)).splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(.*)", line)
        if m:
            text[int(m.group(1), 16)] = " ".join(m.group(2).split())
    return [(int.from_bytes(binary[i:i + 4], "little"), text.get(i, "data")) for i in range(0, len(binary), 4)]


def write(words, path, compiler):
    fw.write_image(words, path,
                   "-- Generated by sw/build.py from sw/board/ (start.S, main.c, link.ld) with\n"
                   f"-- {compiler}.\n"
                   "-- The Arty A7-100T build's IMEM image, for boot mode 2: a UART banner with\n"
                   "-- RESET_SRC, then a watchdog kick and a dot in every window.\n\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if the image differs from a fresh build")
    args = parser.parse_args()

    tools = Toolchain()
    compiler = tools.version()
    words = build(tools, SW / "build")
    if not args.check:
        write(words, IMAGE, compiler)
        print(f"board.elf and board.map in {SW / 'build'}")
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        fresh = Path(tmp) / IMAGE.name
        write(words, fresh, compiler)
        if fresh.read_text(encoding="utf-8") != IMAGE.read_text(encoding="utf-8"):
            print(f"FAIL: {IMAGE.relative_to(ROOT)} differs from a build of sw/board/ with {compiler}")
            return 1
    print(f"ok: {IMAGE.relative_to(ROOT)} matches a build of sw/board/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
