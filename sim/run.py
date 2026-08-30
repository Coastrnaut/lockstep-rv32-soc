import os
import shutil
import subprocess
import sys
from pathlib import Path
from vunit import VUnit

# ==============================================================================
# VUnit Test Runner — lockstep-rv32-soc RISC-V SoC
# ==============================================================================
# Auto-detects simulator: Vivado XSim > hardcoded GHDL > GHDL on PATH
#
# Usage:
#   python sim/run.py --compile    # Compile only
#   python sim/run.py             # Run all tests
#   python sim/run.py --test <name>  # Run a single test
# ==============================================================================

# ---------------------------------------------------------------------------
# Simulator auto-detection
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

def find_simulator():
    """Return ('vivado', None), ('ghdl', path), or ('ghdl', 'auto')."""

    # 1. Check for Vivado XSim on PATH
    if _find_exe("xvlog") and _find_exe("xsim"):
        try:
            result = subprocess.run(
                ["xvlog", "--version"],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                return ("vivado", None)
        except (subprocess.TimeoutExpired, FileNotFoundError):
            # .BAT wrappers fail without Vivado env — if the files exist, trust them
            xvlog_path = _find_exe("xvlog")
            xsim_path = _find_exe("xsim")
            if xvlog_path and xsim_path:
                return ("vivado", None)

    # 2. Check for hardcoded GHDL (Windows)
    if os.name == "nt":
        ghdl_bin = Path(r"C:\GIT\ghdl-mcode-6.0.0-ucrt64\bin")
        if ghdl_bin.is_dir():
            return ("ghdl", str(ghdl_bin))

    # 3. Fall back to GHDL on PATH
    if _find_exe("ghdl"):
        return ("ghdl", "auto")

    # Nothing found
    return (None, None)

detected_name, detected_path = find_simulator()

# ---------------------------------------------------------------------------
# Check if VUnit supports the detected simulator
# ---------------------------------------------------------------------------
# VUnit may not include Vivado/XSim in all builds. If Vivado was detected
# but VUnit lacks it, fall back to GHDL.
vivado_supported = False
try:
    # Try creating a minimal VUnit instance to probe available simulators
    _test_vu = VUnit.from_argv()
    # If we get here, check if vivado options exist
    try:
        _test_vu.set_compile_option("vivado.vcom_flags", [])
        vivado_supported = True
    except ValueError:
        vivado_supported = False
except Exception:
    pass

if detected_name == "vivado" and not vivado_supported:
    print("Vivado XSim found on PATH but not supported by this VUnit build.")
    print("Falling back to GHDL...")
    # Re-detect GHDL
    detected_name, detected_path = ("ghdl", None)
    if os.name == "nt":
        ghdl_bin = Path(r"C:\GIT\ghdl-mcode-6.0.0-ucrt64\bin")
        if ghdl_bin.is_dir():
            detected_path = str(ghdl_bin)
        elif _find_exe("ghdl"):
            detected_path = "auto"
    elif _find_exe("ghdl"):
        detected_path = "auto"
    if detected_path is None:
        print("ERROR: No simulator found.")
        sys.exit(1)

simulator_name = detected_name
sim_path = detected_path

if simulator_name is None:
    print("ERROR: No simulator found.")
    print("  Checked: Vivado XSim (xvlog/xsim on PATH),")
    print("           GHDL (C:\\GIT\\ghdl-mcode-6.0.0-ucrt64\\bin),")
    print("           GHDL (PATH)")
    sys.exit(1)

print(f"Using simulator: {simulator_name}" + (
    f" ({sim_path})" if sim_path and sim_path != "auto" else ""
))

# ---------------------------------------------------------------------------
# Configure VUnit for detected simulator
# ---------------------------------------------------------------------------
if simulator_name == "vivado":
    os.environ["VUNIT_SIMULATOR"] = "vivado"
else:
    os.environ["VUNIT_SIMULATOR"] = "ghdl"
    if sim_path and sim_path != "auto":
        os.environ["VUNIT_GHDL_PATH"] = sim_path
    elif os.name == "nt":
        # Windows without hardcoded path — warn
        print("WARNING: Using PATH ghdl on Windows — may not work")

# Initialize VUnit testing context
vu = VUnit.from_argv(compile_builtins=False)
vu.add_vhdl_builtins()

# Resolve paths relative to this script
root = Path(__file__).parent.parent

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
    neorv32_lib.add_source_files(str(neorv32_rtl) + "/*.vhd")
else:
    print("WARNING: NEORV32 RTL not found at", neorv32_rtl)
    print("  Run: git submodule update --init --recursive")

# ---------------------------------------------------------------------------
# 5. Top-level SoC
# ---------------------------------------------------------------------------
lockstep_lib.add_source_files(root / "rtl" / "top_automotive_soc.vhd")

# ---------------------------------------------------------------------------
# Semantic Safety Lint — ghdl -a --std=08 -Wall
# Catches: missing sensitivity lists, illegal casts, array overflows,
# non-synthesizable constructs. ASIL-D mandatory gate.
# ---------------------------------------------------------------------------
def _run_ghdl_lint(ghdl_exe):
    """Lint all RTL sources with ghdl -a --std=08 -Wall.

    Compiles in dependency order: config -> safety_blocks -> peripherals
    -> neorv32 -> top.  Uses a temp working directory so we don't pollute
    the VUnit object library.
    """
    import tempfile

    # Collect files grouped by library / dependency order
    config_files = sorted((root / "config").glob("*.vhd"))
    safety_files = sorted((root / "rtl" / "safety_blocks").glob("*.vhd"))
    periph_files = sorted((root / "rtl" / "peripherals").glob("*.vhd"))
    top_soc = root / "rtl" / "top_automotive_soc.vhd"
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
            + (1 if top_soc.exists() else 0) + len(neorv32_files)

    if total == 0:
        print("WARNING: No VHDL files found for linting.")
        return True

    print(f"\n{'='*60}")
    print(f"Semantic Safety Lint: ghdl -a --std=08 -Wall")
    print(f"Files: {total}")
    print(f"{'='*60}")

    # Temp directory for the GHDL object library
    with tempfile.TemporaryDirectory(prefix="lockstep_lint_") as tmp:
        # Convert root to MSYS-style path for GHDL in bash
        root_str = str(root).replace("\\", "/")
        # Phase 1: config  -> library lockstep
        if config_files:
            cmd = [ghdl_exe, "-a", "--std=08", "-Wall",
                   "--work=lockstep"] + [str(f).replace("\\", "/") for f in config_files]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300,
                               cwd=tmp)
            if r.returncode != 0:
                print(r.stdout or r.stderr)
                print(f"\nLINT FAILED at config phase (exit {r.returncode}).")
                return False

        # Phase 2: safety_blocks  -> library lockstep
        if safety_files:
            cmd = [ghdl_exe, "-a", "--std=08", "-Wall",
                   "--work=lockstep"] + [str(f).replace("\\", "/") for f in safety_files]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300,
                               cwd=tmp)
            if r.returncode != 0:
                print(r.stdout or r.stderr)
                print(f"\nLINT FAILED at safety_blocks phase (exit {r.returncode}).")
                return False

        # Phase 3: peripherals  -> library lockstep
        if periph_files:
            cmd = [ghdl_exe, "-a", "--std=08", "-Wall",
                   "--work=lockstep"] + [str(f).replace("\\", "/") for f in periph_files]
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

        # Phase 5: top_automotive_soc  -> library lockstep
        if top_soc.exists():
            cmd = [ghdl_exe, "-a", "--std=08", "-Wall",
                   "--work=lockstep", str(top_soc).replace("\\", "/")]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300,
                               cwd=tmp)
            if r.returncode != 0:
                print(r.stdout or r.stderr)
                print(f"\nLINT FAILED at top_soc phase (exit {r.returncode}).")
                return False

    print("\nLint passed — no semantic safety issues found.\n")
    return True

# Resolve the GHDL executable for linting (always use GHDL for lint regardless of simulator)
_ghdl_for_lint = None
if os.name == "nt":
    _ghdl_hardcoded = Path(r"C:\GIT\ghdl-mcode-6.0.0-ucrt64\bin\ghdl.exe")
    if _ghdl_hardcoded.exists():
        _ghdl_for_lint = str(_ghdl_hardcoded)
if not _ghdl_for_lint:
    _ghdl_for_lint = _find_exe("ghdl")

if _ghdl_for_lint:
    if not _run_ghdl_lint(_ghdl_for_lint):
        sys.exit(1)
else:
    print("WARNING: GHDL not found — skipping semantic safety lint.")
    print("  Install ghdl or add to PATH to enable ASIL-D lint gate.")

# ---------------------------------------------------------------------------
# 6. OSVVM libraries (scoreboard, NVC reporter, etc.)
# ---------------------------------------------------------------------------
vu.add_osvvm()

# ---------------------------------------------------------------------------
# 7. Testbenches
# ---------------------------------------------------------------------------
sim_lib = vu.add_library("sim_lib", vhdl_standard="2008")
sim_lib.add_source_files(root / "sim" / "testbenches" / "*.vhd")

# ---------------------------------------------------------------------------
# Simulator-specific options
# ---------------------------------------------------------------------------
if simulator_name == "vivado":
    # XSim: relax strictness for mixed-std projects, verbose on failure
    vu.set_compile_option("vivado.vcom_flags", ["-relax"])
    vu.set_sim_option("vivado.xsim_flags", ["-v", "1"])
else:
    # GHDL: no coverage flags (mcode backend lacks coverage support)
    pass

# ---------------------------------------------------------------------------
# Ensure reports/ directory exists (OSVVM writes OsvvmRun.yml here)
# Must be relative to sim/ since that's the working directory
# ---------------------------------------------------------------------------
os.makedirs("reports", exist_ok=True)

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
vu.main()
