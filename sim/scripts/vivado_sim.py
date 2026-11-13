#!/usr/bin/env python3
"""The Vivado stage of the regression: xvhdl, xelab and xsim.

sim/run.py runs this when it finds Vivado (and `python run.py --vivado` runs
only this). It cannot run the VUnit benches on xsim: VUnit has no xsim
interface, and xsim's static elaboration fails inside VUnit's own pointer
packages (integer_vector_ptr_pkg, either body) for every bench, which no xelab
option changes. So this stage checks what xsim can check:

  1. Analysis.    Every file the GHDL regression compiles, in VUnit's order,
                  through xvhdl --2008: our RTL, NEORV32, the benches, VUnit
                  and OSVVM. A second compiler catches what GHDL accepts and a
                  vendor tool would not.
  2. Elaboration. xelab of the SoC (with both NEORV32 cores) and of every
                  first-party RTL entity.
  3. Simulation.  The plain-VHDL benches (no VUnit) run on xsim and on GHDL,
                  and must pass on both: the simulation firmware on the SoC
                  (sim/portable/tb_soc_smoke.vhd) and the Arty board image
                  (fpga/arty_a7_100t/ghdl/tb_board_firmware.vhd).

Vivado is found from VIVADO_BIN (its bin folder), XILINX_VIVADO, PATH, then
the default install folders. Work goes to sim/vunit_out/vivado.
"""
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WRAPPERS = ("automotive_can_controller", "ecc_data_ram", "watchdog_supervisor")
INSTALL_GLOBS = ["C:/AMDDesignTools/*/Vivado/bin", "C:/Xilinx/Vivado/*/bin", "C:/Xilinx/*/Vivado/bin",
                 "/tools/Xilinx/Vivado/*/bin", "/tools/Xilinx/*/Vivado/bin", "/opt/Xilinx/Vivado/*/bin"]


def _tool(bindir, name):
    exe = Path(bindir) / (name + (".bat" if os.name == "nt" else ""))
    return str(exe) if exe.is_file() else None


def find_vivado_bin():
    """The Vivado bin folder holding xvhdl, xelab and xsim, or None."""
    candidates = []
    if os.environ.get("VIVADO_BIN"):
        candidates.append(Path(os.environ["VIVADO_BIN"]))
    if os.environ.get("XILINX_VIVADO"):
        candidates.append(Path(os.environ["XILINX_VIVADO"]) / "bin")
    found = shutil.which("xvhdl")
    if found:
        candidates.append(Path(found).parent)
    for pattern in INSTALL_GLOBS:
        anchor = Path(pattern.split("*")[0])
        if anchor.exists():
            rest = pattern[len(str(anchor).replace("\\", "/")):].lstrip("/")
            candidates.extend(sorted(anchor.glob(rest), reverse=True))
    for c in candidates:
        if all(_tool(c, t) for t in ("xvhdl", "xelab", "xsim")):
            return c
    return None


def _run(cmd, cwd, log, timeout=3600):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    Path(log).write_text(r.stdout + r.stderr, encoding="utf-8")
    return r


def _errors(text, limit=8):
    return [line for line in text.splitlines() if line.startswith("ERROR")][:limit]


def rtl_sources(image):
    """(library, file) for the SoC with the given IMEM image, in analysis order."""
    files = [("lockstep", ROOT / "config" / "package_soc_types.vhd")]
    for folder in ("safety_blocks", "peripherals"):
        for f in sorted((ROOT / "rtl" / folder).glob("*.vhd"), key=lambda f: (f.stem in WRAPPERS, f.stem)):
            files.append(("lockstep", f))
    neorv32 = ROOT / "rtl" / "core" / "neorv32"
    # The image comes first: NEORV32's IMEM uses it
    files.append(("neorv32", image))
    for line in (neorv32 / "rtl" / "file_list_core.f").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("--") and not line.endswith("neorv32_imem_image.vhd"):
            files.append(("neorv32", Path(line.replace("$NEORV32_HOME", str(neorv32)))))
    files += [("lockstep", ROOT / "rtl" / "lockstep_core.vhd"), ("lockstep", ROOT / "rtl" / "top_automotive_soc.vhd")]
    return files


# The plain-VHDL benches: name, IMEM image, bench files (library work), run time, pass text
PORTABLE = [
    ("tb_soc_smoke", ROOT / "sim" / "firmware" / "neorv32_imem_image.vhd",
     [ROOT / "sim" / "testbenches" / "can_test_pkg.vhd", ROOT / "sim" / "testbenches" / "can_test_node.vhd",
      ROOT / "sim" / "portable" / "tb_soc_smoke.vhd"], "5ms", "SOC SMOKE PASS"),
    ("tb_board_firmware", ROOT / "fpga" / "arty_a7_100t" / "board_imem_image.vhd",
     [ROOT / "fpga" / "arty_a7_100t" / "ghdl" / "tb_board_firmware.vhd"], "30ms", "BOARD FIRMWARE PASS"),
]


def _prj(files, path):
    lines = [f'vhdl2008 {lib} "{Path(f).resolve().as_posix()}"' for lib, f in files]
    Path(path).write_text("\n".join(lines + ["nosort"]) + "\n", encoding="utf-8")


def analyse(bindir, compile_order, work):
    """Step 1: every file, in VUnit's order."""
    work.mkdir(parents=True, exist_ok=True)
    _prj(compile_order, work / "all.prj")
    r = _run([_tool(bindir, "xvhdl"), "-prj", "all.prj", "--relax", "--nolog"], work, work / "xvhdl.log")
    return r.returncode == 0, f"{len(compile_order)} files", _errors(r.stdout)


def elaborate(bindir, work):
    """Step 2: the SoC and each first-party RTL entity, from step 1's libraries."""
    units = [f.stem for d in ("safety_blocks", "peripherals") for f in sorted((ROOT / "rtl" / d).glob("*.vhd"))]
    units += ["lockstep_core", "top_automotive_soc"]
    cmd = [_tool(bindir, "xelab"), "--relax", "--debug", "off", "--nolog", "-L", "lockstep", "-L", "neorv32",
           "-s", "rtl_elab"] + [f"lockstep.{u}" for u in units]
    r = _run(cmd, work, work / "xelab_rtl.log")
    return r.returncode == 0, f"{len(units)} entities", _errors(r.stdout)


def _xsim_bench(bindir, name, image, bench_files, run_time, work):
    d = work / f"xsim_{name}"
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    _prj(rtl_sources(image) + [("work", f) for f in bench_files], d / "bench.prj")
    r = _run([_tool(bindir, "xvhdl"), "-prj", "bench.prj", "--relax", "--nolog"], d, d / "xvhdl.log")
    if r.returncode:
        return False, "analysis failed", _errors(r.stdout)
    r = _run([_tool(bindir, "xelab"), "--relax", "--debug", "off", "--nolog", "-L", "lockstep", "-L", "neorv32",
              "-s", "snap", f"work.{name}"], d, d / "xelab.log")
    if r.returncode:
        return False, "elaboration failed", _errors(r.stdout)
    (d / "run.tcl").write_text(f"run {run_time}\nquit\n", encoding="utf-8")
    r = _run([_tool(bindir, "xsim"), "snap", "--nolog", "-tclbatch", "run.tcl"], d, d / "xsim.log")
    return r.stdout, None, None


def _ghdl_bench(ghdl, name, image, bench_files, run_time, work):
    d = work / f"ghdl_{name}"
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    # One file at a time, in source order: the top in lockstep needs neorv32 first
    log = []
    for lib, f in rtl_sources(image) + [("work", f) for f in bench_files]:
        r = subprocess.run([ghdl, "-a", "--std=08", f"--work={lib}", Path(f).resolve().as_posix()],
                           cwd=d, capture_output=True, text=True)
        log.append(r.stdout + r.stderr)
        if r.returncode:
            (d / "ghdl.log").write_text("".join(log), encoding="utf-8")
            return False, f"analysis of {Path(f).name} failed", (r.stdout + r.stderr).splitlines()[:8]
    r = subprocess.run([ghdl, "--elab-run", "--std=08", name, f"--stop-time={run_time}"],
                       cwd=d, capture_output=True, text=True, timeout=3600)
    (d / "ghdl.log").write_text("".join(log) + r.stdout + r.stderr, encoding="utf-8")
    return r.stdout + r.stderr, None, None


def _verdict(output, pass_text):
    if output is None:
        return False, "did not run"
    passed = [l for l in output.splitlines() if pass_text in l]
    failed = [l for l in output.splitlines() if "FAIL:" in l or "Failure" in l]
    if passed and not failed:
        return True, passed[0].split(pass_text, 1)[1].strip(": ").strip()
    return False, (failed or ["no pass message"])[0].strip()


def simulate(bindir, ghdl, work):
    """Step 3: each plain-VHDL bench on xsim and on GHDL."""
    results = []
    for name, image, bench_files, run_time, pass_text in PORTABLE:
        for sim in ("xsim", "ghdl"):
            if sim == "ghdl" and not ghdl:
                results.append((name, sim, False, "GHDL not found", []))
                continue
            start = time.time()
            if sim == "xsim":
                out, why, errs = _xsim_bench(bindir, name, image, bench_files, run_time, work)
            else:
                out, why, errs = _ghdl_bench(ghdl, name, image, bench_files, run_time, work)
            if out is False:
                results.append((name, sim, False, why, errs))
                continue
            ok, detail = _verdict(out, pass_text)
            results.append((name, sim, ok, f"{detail} ({time.time() - start:.0f} s)", []))
    return results


def run_stage(compile_order, ghdl, work=None):
    """All three steps. compile_order is [(library, file)]. Returns True if all pass."""
    bindir = find_vivado_bin()
    if bindir is None:
        print("ERROR: Vivado not found. Set VIVADO_BIN to its bin folder.")
        return False
    work = Path(work or ROOT / "sim" / "vunit_out" / "vivado")
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    print(f"\n{'=' * 60}\nVivado stage: {bindir}\n{'=' * 60}", flush=True)
    rows = []
    ok_all = True
    for label, step in (("analysis (xvhdl)", lambda: analyse(bindir, compile_order, work)),
                        ("elaboration (xelab)", lambda: elaborate(bindir, work))):
        start = time.time()
        ok, what, errs = step()
        rows.append((label, ok, f"{what} ({time.time() - start:.0f} s)"))
        ok_all &= ok
        print(f"{'pass' if ok else 'FAIL'}  {label}: {what}", flush=True)
        for e in errs:
            print("      " + e)
    for name, sim, ok, detail, errs in simulate(bindir, ghdl, work):
        rows.append((f"{name} on {sim}", ok, detail))
        ok_all &= ok
        print(f"{'pass' if ok else 'FAIL'}  {name} on {sim}: {detail}", flush=True)
        for e in errs:
            print("      " + e)
    print(f"Vivado stage {'passed' if ok_all else 'FAILED'}; logs in {work}\n", flush=True)
    return ok_all


if __name__ == "__main__":
    sys.exit("Run this through sim/run.py --vivado, which supplies the compile order.")
