#!/usr/bin/env python3
"""Build the programs in sw/ with the pinned compiler (roadmap R3.3).

Each program is sw/common/start.S and its own main.c, linked by
sw/common/link.ld, into sw/build/<program>/<program>.elf with its map file,
and then the IMEM image that boot mode 2 runs, one commented word per line:

  board  the Arty A7-100T board program  fpga/arty_a7_100t/board_imem_image.vhd
  hello  hello, world                    sw/hello/hello_imem_image.vhd

The compiler is pinned: xPack GNU RISC-V Embedded GCC 15.2.0-1. Another
version may produce other code, so the images are only written, or checked,
with that one. It is found from:

  RISCV_PREFIX  the tools' prefix, e.g. /opt/xpack/bin/riscv-none-elf-
  PATH          riscv-none-elf-gcc
  WSL           on Windows, ~/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin in
                each WSL distribution (RISCV_WSL_DISTRO picks one)

    python sw/build.py                build every program, and write the images
    python sw/build.py hello          one program
    python sw/build.py --check        build, and fail if an image differs
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
COMMON = SW / "common"
LINKER_SCRIPT = COMMON / "link.ld"

# Each program: its folder, its image, and what the image's header says it does
PROGRAMS = {
    "board": (SW / "board", ROOT / "fpga" / "arty_a7_100t" / "board_imem_image.vhd",
              "The Arty A7-100T build's IMEM image, for boot mode 2: a UART banner with\n"
              "-- RESET_SRC, the ECC RAM and CAN results, then a watchdog kick and a dot in\n"
              "-- every window."),
    "hello": (SW / "hello", SW / "hello" / "hello_imem_image.vhd",
              "Hello, world, for boot mode 2: one line on the UART, then the watchdog kept\n"
              "-- content."),
}

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
            raise SystemExit(f"ERROR: the images need {PINNED} {PINNED_RELEASE}, found: {first}")
        return first


def build(tools, name, folder, out):
    """Compile and link one program into out; returns the image's words with their text."""
    out.mkdir(parents=True, exist_ok=True)
    objects = []
    for src in [COMMON / "start.S", folder / "main.c"]:
        obj = out / (src.stem + ".o")
        tools.run("gcc", *CFLAGS, "-I" + tools.path(COMMON), "-I" + tools.path(SW / "include"),
                  "-c", tools.path(src), "-o", tools.path(obj))
        objects.append(tools.path(obj))
    elf = out / f"{name}.elf"
    tools.run("gcc", *CFLAGS, "-T", tools.path(LINKER_SCRIPT), "-Wl,--gc-sections",
              "-Wl,-Map=" + tools.path(out / f"{name}.map"), *objects, "-o", tools.path(elf))
    binary_path = out / f"{name}.bin"
    tools.run("objcopy", "-O", "binary", "--only-section=.text", tools.path(elf), tools.path(binary_path))
    binary = binary_path.read_bytes()
    binary += b"\0" * (-len(binary) % 4)

    # One comment per word: the instruction, from the disassembler; constants
    # in the image are "data"
    text = {}
    for line in tools.run("objdump", "-d", "-M", "no-aliases", tools.path(elf)).splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(.*)", line)
        if m:
            text[int(m.group(1), 16)] = " ".join(m.group(2).split())
    return [(int.from_bytes(binary[i:i + 4], "little"), text.get(i, "data")) for i in range(0, len(binary), 4)]


def write(words, path, name, what, compiler):
    fw.write_image(words, path,
                   f"-- Generated by sw/build.py from sw/{name}/main.c and sw/common/ with\n"
                   f"-- {compiler}.\n"
                   f"-- {what}\n\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("programs", nargs="*", choices=[[]] + list(PROGRAMS), default=[],
                        help="programs to build (all when none is named)")
    parser.add_argument("--check", action="store_true", help="fail if an image differs from a fresh build")
    args = parser.parse_args()

    tools = Toolchain()
    compiler = tools.version()
    failed = 0
    for name in args.programs or list(PROGRAMS):
        folder, image, what = PROGRAMS[name]
        words = build(tools, name, folder, SW / "build" / name)
        if not args.check:
            write(words, image, name, what, compiler)
            continue
        with tempfile.TemporaryDirectory() as tmp:
            fresh = Path(tmp) / image.name
            write(words, fresh, name, what, compiler)
            if fresh.read_text(encoding="utf-8") != image.read_text(encoding="utf-8"):
                print(f"FAIL: {image.relative_to(ROOT)} differs from a build of sw/{name}/ with {compiler}")
                failed += 1
            else:
                print(f"ok: {image.relative_to(ROOT)} matches a build of sw/{name}/")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
