import os
import shutil
import subprocess
import sys
from pathlib import Path
from vunit import VUnit

# ==============================================================================
# VUnit Test Runner — lockstep-rv32-soc RISC-V SoC
# ==============================================================================
# Simulator: GHDL with the mcode backend, chosen in one place, in this order:
#   1. VUNIT_GHDL_PATH, the directory holding the ghdl executable
#   2. on Windows, the first of these that exists:
#      C:\GIT\ghdl-mcode-6.0.0-ucrt64\bin, C:\GIT\ghdl-mcode-6.0.0-rc2-mingw64\bin
#   3. ghdl on PATH (Linux and CI)
#
# Vivado: when Vivado is installed (VIVADO_BIN, XILINX_VIVADO, PATH or the default
# install folders), the lint gates are followed by a Vivado stage
# (sim/scripts/vivado_sim.py): every file analysed by xvhdl, the SoC elaborated
# by xelab, and the plain-VHDL benches run on both xsim and GHDL. xsim cannot run
# the VUnit benches themselves; vivado_sim.py says why.
# Licensed simulators are not selected here. They need a job of their own,
# with their own tool versions and evidence. The Python tools are pinned in
# sim/requirements.txt. OSVVM is VUnit's bundled copy (vu.add_osvvm()): the
# sim/OsvvmLibraries submodule is not compiled by this runner.
#
# Usage, from sim/:
#   python run.py --compile             # Compile only
#   python run.py                       # Lint gates, then every test
#   python run.py --lint | --vsg        # One lint gate only, then exit
#   python run.py --vsg-fix             # Let vsg fix what it can, then exit
#   python run.py --vivado              # The Vivado stage only, then exit
#   LOCKSTEP_NO_VIVADO=1 python run.py  # Skip the Vivado stage
#   python run.py "sim_lib.tb_soc_ecc.*" -p 4 --xunit-xml vunit_out/out.xml
#   LOCKSTEP_NO_LINT=1 python run.py    # Skip the lint gates, as mutation runs do
#
# GHDL writes its library files into the working directory (see the --workdir
# note below), so two runs from the same directory at once are not supported.
# ==============================================================================

_WINDOWS_GHDL = [Path(r"C:\GIT\ghdl-mcode-6.0.0-ucrt64\bin"), Path(r"C:\GIT\ghdl-mcode-6.0.0-rc2-mingw64\bin")]


# ---------------------------------------------------------------------------
# Simulator selection
# ---------------------------------------------------------------------------
def _find_exe(name):
    """Cross-platform find: tries shutil.which first, then PATH scan."""
    p = shutil.which(name)
    if p:
        return p
    # Fallback: scan PATH dirs manually (handles MSYS/WSL path issues)
    for d in os.environ.get("PATH", "").split(os.pathsep):
        for ext in ("", ".exe"):
            candidate = os.path.join(d, name + ext)
            if os.path.isfile(candidate):
                return candidate
    return None

def find_ghdl():
    """Return (directory or None, ghdl executable or None), in the order above."""
    explicit = os.environ.get("VUNIT_GHDL_PATH")
    if explicit:
        for name in ("ghdl", "ghdl.exe"):
            exe = Path(explicit) / name
            if exe.is_file():
                return explicit, str(exe)
        print(f"ERROR: VUNIT_GHDL_PATH={explicit} holds no ghdl executable.")
        sys.exit(1)
    if os.name == "nt":
        for folder in _WINDOWS_GHDL:
            if (folder / "ghdl.exe").is_file():
                return str(folder), str(folder / "ghdl.exe")
    return None, _find_exe("ghdl")


# Parse standalone lint flags: --lint runs only ghdl lint, --vsg runs only vsg.
# When neither is present, the full pipeline (lint → compile → test) runs.
_lint_only = "--lint" in sys.argv
_vsg_only = "--vsg" in sys.argv
_vsg_fix = "--vsg-fix" in sys.argv
_vivado_only = "--vivado" in sys.argv
sys.argv = [a for a in sys.argv if a not in ("--lint", "--vsg", "--vsg-fix", "--vivado")]
_vsg_only = _vsg_only or _vsg_fix

ghdl_dir, ghdl_exe = find_ghdl()
if ghdl_exe is None and not _vsg_only:
    print("ERROR: GHDL not found. Set VUNIT_GHDL_PATH or put ghdl on PATH.")
    sys.exit(1)

print(f"Using simulator: {os.environ.get('VUNIT_SIMULATOR', 'ghdl')} (GHDL {ghdl_exe})")

# ---------------------------------------------------------------------------
# Configure VUnit for GHDL
# ---------------------------------------------------------------------------

root = Path(__file__).parent.parent
# GHDL 6.0.0 in MSYS bash cannot parse Windows backslash paths in -P/--workdir.
# Monkey-patch VUnit's GHDL interface so all library directory paths are
# converted to MSYS forward-slash paths before GHDL sees them. The patch applies
# on every platform, including the Linux GHDL 4.1 in CI, where it also drops
# --workdir. Narrowing it to Windows would move CI's library files, so that
# waits for a CI run that checks it (docs/verification/milestone_0_1.md).
from vunit.sim_if.ghdl import GHDLInterface
_orig_compile_cmd = GHDLInterface.compile_vhdl_file_command
_orig_get_command = GHDLInterface._get_command

def _to_msys(p):
    """Convert Windows backslash paths to forward-slash paths for GHDL 6.0.0."""
    return p.replace("\\", "/")

def _fix_paths_cmd(self, source_file):
    cmd = _orig_compile_cmd(self, source_file)
    fixed = []
    for token in cmd:
        # GHDL 6.0.0 does not support --workdir — skip it
        if token.startswith("--workdir="):
            continue
        if token.startswith("-P"):
            fixed.append("-P" + _to_msys(token[2:]))
        else:
            fixed.append(token)
    return fixed

def _fix_paths_sim(self, config, output_path, elaborate_only, ghdl_e, wave_file):
    cmd = _orig_get_command(self, config, output_path, elaborate_only, ghdl_e, wave_file)
    fixed = []
    for token in cmd:
        if token.startswith("--workdir="):
            continue
        if token.startswith("-P"):
            fixed.append("-P" + _to_msys(token[2:]))
        else:
            fixed.append(token)
    return fixed

GHDLInterface.compile_vhdl_file_command = _fix_paths_cmd
GHDLInterface._get_command = _fix_paths_sim

# GHDL unless VUNIT_SIMULATOR names another simulator VUnit supports, such as
# modelsim for Questa at sign-off. Only GHDL is tested here; the lint gates
# always use GHDL.
os.environ.setdefault("VUNIT_SIMULATOR", "ghdl")
if ghdl_dir:
    os.environ["VUNIT_GHDL_PATH"] = ghdl_dir

# Initialize VUnit testing context
vu = VUnit.from_argv(compile_builtins=False)
vu.add_vhdl_builtins()

# ---------------------------------------------------------------------------
# 1. Custom types package (must compile first — other files depend on it)
# ---------------------------------------------------------------------------
lockstep_lib = vu.add_library("lockstep", vhdl_standard="2008")
lockstep_lib.add_source_files(root / "config" / "package_soc_types.vhd")

# ---------------------------------------------------------------------------
# 2. Safety blocks
# ---------------------------------------------------------------------------
lockstep_lib.add_source_files(root / "rtl" / "safety_blocks" / "*.vhd")

# ---------------------------------------------------------------------------
# 3. Peripherals
# ---------------------------------------------------------------------------
lockstep_lib.add_source_files(root / "rtl" / "peripherals" / "*.vhd")

# ---------------------------------------------------------------------------
# 4. NEORV32 submodule (compile into its own library)
# ---------------------------------------------------------------------------
neorv32_lib = vu.add_library("neorv32", vhdl_standard="2008")
neorv32_rtl = root / "rtl" / "core" / "neorv32" / "rtl" / "core"
if neorv32_rtl.exists():
    # The test firmware takes the place of the default IMEM image
    neorv32_lib.add_source_files([str(f) for f in neorv32_rtl.glob("*.vhd")
                                  if f.name != "neorv32_imem_image.vhd"])
    neorv32_lib.add_source_files(root / "sim" / "firmware" / "neorv32_imem_image.vhd")
else:
    print("WARNING: NEORV32 RTL not found at", neorv32_rtl)
    print("  Run: git submodule update --init --recursive")

# ---------------------------------------------------------------------------
# 5. The core wrapper both lockstep cores use, and the top-level SoC
# ---------------------------------------------------------------------------
lockstep_lib.add_source_files(root / "rtl" / "lockstep_core.vhd")
lockstep_lib.add_source_files(root / "rtl" / "top_automotive_soc.vhd")

# ---------------------------------------------------------------------------
# Semantic Safety Lint — ghdl -a --std=08 -Wall, then ghdl --synth
# Analysis catches type errors and incomplete sensitivity lists. Synthesis
# catches signals driven from two processes, inferred latches and
# non-synthesizable constructs, all of which analysis accepts. ASIL-D
# mandatory gate.
# ---------------------------------------------------------------------------
def _run_ghdl_lint(ghdl_exe):
    """Lint all RTL sources: ghdl -a --std=08 -Wall, then ghdl --synth.

    Compiles in dependency order: config -> safety_blocks -> peripherals
    -> neorv32 -> top.  Uses a temp working directory so we don't pollute
    the VUnit object library.
    """
    import tempfile

    # Collect files grouped by library / dependency order
    config_files = sorted((root / "config").glob("*.vhd"))

    # Analysis follows this order, so a block has to come after any it instantiates
    wrappers = ("automotive_can_controller", "ecc_data_ram", "watchdog_supervisor")
    safety_files = sorted((root / "rtl" / "safety_blocks").glob("*.vhd"),
                          key=lambda f: (f.stem in wrappers, f.stem))
    periph_files = sorted((root / "rtl" / "peripherals").glob("*.vhd"),
                          key=lambda f: (f.stem in wrappers, f.stem))
    top_soc = root / "rtl" / "top_automotive_soc.vhd"
    # Both cores are this one NEORV32 wrapper; it is analysed before the top
    core_wrapper = root / "rtl" / "lockstep_core.vhd"
    # NEORV32: use file_list_core.f for correct dependency order
    neorv32_files = []
    fl = root / "rtl" / "core" / "neorv32" / "rtl" / "file_list_core.f"
    if fl.exists():
        neorv32_home = root / "rtl" / "core" / "neorv32"
        neorv32_home_s = str(neorv32_home).replace("\\", "/")
        for line in fl.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("--"):
                continue
            p = line.replace("$NEORV32_HOME", neorv32_home_s)
            if Path(p).exists():
                neorv32_files.append(p)

    total = len(config_files) + len(safety_files) + len(periph_files) \
            + (2 if top_soc.exists() else 0) + len(neorv32_files)

    if total == 0:
        print("WARNING: No VHDL files found for linting.")
        return True

    print(f"\n{'='*60}")
    print(f"Semantic Safety Lint: ghdl -a --std=08 -Wall, then ghdl --synth")
    print(f"Files: {total}")
    print(f"{'='*60}")

    # Temp directory for the GHDL object library
    with tempfile.TemporaryDirectory(prefix="lockstep_lint_") as tmp:
        # Convert root to MSYS-style path for GHDL in bash
        root_str = str(root).replace("\\", "/")
        # Analysis of our own RTL: an incomplete sensitivity list is only a
        # warning by default. NEORV32 in phase 4 is third-party.
        analyse = [ghdl_exe, "-a", "--std=08", "-Wall", "-Werror=sensitivity",
                   "--work=lockstep"]
        # Phase 1: config  -> library lockstep
        if config_files:
            cmd = analyse + [str(f).replace("\\", "/") for f in config_files]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300,
                               cwd=tmp)
            if r.returncode != 0:
                print(r.stdout or r.stderr)
                print(f"\nLINT FAILED at config phase (exit {r.returncode}).")
                return False

        # Phase 2: safety_blocks  -> library lockstep
        if safety_files:
            cmd = analyse + [str(f).replace("\\", "/") for f in safety_files]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300,
                               cwd=tmp)
            if r.returncode != 0:
                print(r.stdout or r.stderr)
                print(f"\nLINT FAILED at safety_blocks phase (exit {r.returncode}).")
                return False

        # Phase 3: peripherals  -> library lockstep
        if periph_files:
            cmd = analyse + [str(f).replace("\\", "/") for f in periph_files]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300,
                               cwd=tmp)
            if r.returncode != 0:
                print(r.stdout or r.stderr)
                print(f"\nLINT FAILED at peripherals phase (exit {r.returncode}).")
                return False

        # Phase 4: neorv32  -> library neorv32
        if neorv32_files:
            cmd = [ghdl_exe, "-a", "--std=08", "-Wall",
                   "--work=neorv32"] + [str(f).replace("\\", "/") for f in neorv32_files]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300,
                               cwd=tmp)
            if r.returncode != 0:
                print(r.stdout or r.stderr)
                print(f"\nLINT FAILED at neorv32 phase (exit {r.returncode}).")
                return False

        # Phase 5: the core wrapper and top_automotive_soc  -> library lockstep
        if top_soc.exists():
            cmd = analyse + [str(f).replace("\\", "/") for f in (core_wrapper, top_soc)]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300,
                               cwd=tmp)
            if r.returncode != 0:
                print(r.stdout or r.stderr)
                print(f"\nLINT FAILED at top_soc phase (exit {r.returncode}).")
                return False

        # Phase 6: synthesis of each block, then the whole SoC. Each file holds
        # the entity it is named after.
        units = [f.stem for f in safety_files + periph_files]
        if top_soc.exists():
            units.append(top_soc.stem)
        for unit in units:
            cmd = [ghdl_exe, "--synth", "--std=08", "--work=lockstep", unit]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300,
                               cwd=tmp)
            if r.returncode != 0:
                print(r.stderr)
                print(f"\nLINT FAILED synthesising {unit} (exit {r.returncode}).")
                return False

    print("\nLint passed — no semantic safety issues found.\n")
    return True


# ---------------------------------------------------------------------------
# Style Lint — vsg (VHDL Style Guide)
# Catches: whitespace, indentation, keyword alignment, naming conventions.
# Runs on our RTL + testbenches, skips NEORV32 (third-party).
# ---------------------------------------------------------------------------
def _vsg_file_sets():
    """First-party VHDL in two sets: RTL, and the VUnit benches."""
    rtl = []
    rtl.extend(sorted((root / "config").glob("*.vhd")))
    rtl.extend(sorted((root / "rtl" / "safety_blocks").glob("*.vhd")))
    rtl.extend(sorted((root / "rtl" / "peripherals").glob("*.vhd")))
    for top in (root / "rtl" / "lockstep_core.vhd", root / "rtl" / "top_automotive_soc.vhd"):
        if top.exists():
            rtl.append(top)
    benches = sorted((root / "sim" / "testbenches").glob("*.vhd")) + sorted((root / "sim" / "portable").glob("*.vhd"))
    return rtl, benches


def _run_vsg(vsg_exe, fix=False):
    """Run vsg over every first-party VHDL file (not NEORV32).

    sim/vsg_config.yaml enables every VSG rule (sim/scripts/vsg_config.py writes
    it). The benches also read sim/vsg_testbench.yaml, which turns off the few
    rules a VUnit bench cannot follow.
    """
    rtl, benches = _vsg_file_sets()
    config = str(root / "sim" / "vsg_config.yaml")
    bench_config = str(root / "sim" / "vsg_testbench.yaml")

    print(f"\n{'='*60}")
    print("Style Lint: vsg" + (" --fix" if fix else ""))
    print(f"Files: {len(rtl)} RTL, {len(benches)} benches")
    print(f"{'='*60}")

    ok = True
    for files, configs in ((rtl, [config]), (benches, [config, bench_config])):
        if not files:
            continue
        # vsg takes --fix or -ap (report every phase), not both
        cmd = [vsg_exe, "-c"] + configs + (["--fix"] if fix else ["-ap"]) + ["-f"] + \
              [str(f).replace("\\", "/") for f in files]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            print(r.stdout)
            ok = False
    if not ok:
        print("\nVSG FAILED.")
        return False

    print("\nVSG passed — no style violations found.\n")
    return True


# Resolve executables: the lint uses the same GHDL as the simulation
_ghdl_for_lint = ghdl_exe
_vsg_exe = _find_exe("vsg")

# ---------------------------------------------------------------------------
# Lint gates
# --lint : run only ghdl semantic lint, then exit
# --vsg  : run only vsg style lint, then exit
# (no flag) : run both, then continue to compile + test
# A gate whose tool is missing fails rather than being skipped.
# ---------------------------------------------------------------------------
def _do_lint():
    if not _ghdl_for_lint or not _run_ghdl_lint(_ghdl_for_lint):
        sys.exit(1)

    if not _vsg_exe:
        print("ERROR: vsg not found. pip install -r sim/requirements.txt, or set LOCKSTEP_NO_LINT.")
        sys.exit(1)
    if not _run_vsg(_vsg_exe):
        sys.exit(1)

if _lint_only:
    if _ghdl_for_lint:
        if not _run_ghdl_lint(_ghdl_for_lint):
            sys.exit(1)
    else:
        print("ERROR: GHDL not found.")
        sys.exit(1)
    sys.exit(0)

if _vsg_only:
    if _vsg_exe:
        if not _run_vsg(_vsg_exe, fix=_vsg_fix):
            sys.exit(1)
    else:
        print("ERROR: vsg not found.")
        sys.exit(1)
    sys.exit(0)

# Full pipeline — run both linters, unless LOCKSTEP_NO_LINT is set. The mutation
# campaign (sim/scripts/mutate.py) sets it: a mutant can be legal VHDL that
# breaks a style rule, and it still has to reach the tests.
if os.environ.get("LOCKSTEP_NO_LINT"):
    print("Lint gates skipped: LOCKSTEP_NO_LINT is set.")
elif not _vivado_only:
    _do_lint()

# ---------------------------------------------------------------------------
# 6. OSVVM libraries (scoreboard, NVC reporter, etc.)
# ---------------------------------------------------------------------------
vu.add_osvvm()

# ---------------------------------------------------------------------------
# 7. Testbenches
# ---------------------------------------------------------------------------
sim_lib = vu.add_library("sim_lib", vhdl_standard="2008")
sim_lib.add_source_files(root / "sim" / "testbenches" / "*.vhd")
sim_lib.add_source_files(root / "sim" / "generated" / "*.vhd")

# Fault campaign (sim/scripts/fault_campaign.py): one configuration of
# tb_fault_campaign per trial in the manifest that LOCKSTEP_CAMPAIGN names.
# Without it the bench runs once, with no fault, as part of the regression.
_campaign = os.environ.get("LOCKSTEP_CAMPAIGN")
if _campaign:
    import csv
    _bench = sim_lib.test_bench("tb_fault_campaign")
    # A fault can trip the RTL's own simulation assertions. They are evidence
    # of a fault, not hardware, so they must not end the trial.
    _bench.set_sim_option("vhdl_assert_stop_level", "failure")
    with open(_campaign, newline="") as _fh:
        for _row in csv.DictReader(_fh):
            _bench.add_config(
                name=f"trial_{int(_row['trial']):04d}",
                generics={f"g_{key}": int(_row[key])
                          for key in ("trial", "site", "bit", "kind", "duration", "inject_ns", "run_us")})

# RAM profiles (roadmap R4.3): the SoC's bus probes run on the full 256 KB RAM
# and on a 32 KB one, whose end the program's last-word probes lie beyond
_probe = sim_lib.test_bench("tb_soc_fabric").test(
    "probes_get_one_response_each_and_unmapped_ones_change_nothing")
for _bits, _name in ((15, "ram_256k"), (12, "ram_32k")):
    _probe.add_config(name=_name, generics={"g_ram_addr_bits": _bits})

# ---------------------------------------------------------------------------
# GHDL options
# ---------------------------------------------------------------------------
vu.set_sim_option("ghdl.elab_flags", ["--std=08"])
# Hang guard: a bench whose clock never starts otherwise simulates forever.
# The longest bench needs about 6 ms of simulated time.
vu.set_sim_option("ghdl.sim_flags", ["--stop-time=50ms"])

# ---------------------------------------------------------------------------
# Ensure reports/ directory exists (OSVVM writes OsvvmRun.yml here)
# Must be relative to sim/ since that's the working directory
# ---------------------------------------------------------------------------
os.makedirs("reports", exist_ok=True)

# ---------------------------------------------------------------------------
# Vivado stage: with --vivado alone, or after the lint gates when Vivado is
# installed. CI has no Vivado, so it runs the GHDL regression only.
# ---------------------------------------------------------------------------
sys.path.insert(0, str(root / "sim" / "scripts"))
import vivado_sim  # noqa: E402

_vivado_wanted = _vivado_only or (not os.environ.get("LOCKSTEP_NO_LINT") and not os.environ.get("LOCKSTEP_NO_VIVADO")
                                  and vivado_sim.find_vivado_bin() is not None)
if _vivado_wanted:
    _order = [(f.library.name, f.name) for f in vu.get_compile_order()]
    _vivado_ok = vivado_sim.run_stage(_order, ghdl_exe)
    if _vivado_only or not _vivado_ok:
        sys.exit(0 if _vivado_ok else 1)

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
vu.main()
