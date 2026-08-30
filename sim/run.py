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
def find_simulator():
    """Return ('vivado', None), ('ghdl', path), or ('ghdl', 'auto')."""

    # 1. Check for Vivado XSim on PATH
    if shutil.which("xvlog") and shutil.which("xsim"):
        # Verify Vivado actually works (handles installed but not licensed)
        try:
            result = subprocess.run(
                ["xvlog", "--version"],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                return ("vivado", None)
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    # 2. Check for hardcoded GHDL (Windows)
    if os.name == "nt":
        ghdl_bin = Path(r"C:\GIT\ghdl-mcode-6.0.0-rc2-mingw64\bin")
        if ghdl_bin.is_dir():
            return ("ghdl", str(ghdl_bin))

    # 3. Fall back to GHDL on PATH
    if shutil.which("ghdl"):
        return ("ghdl", "auto")

    # Nothing found
    return (None, None)

simulator_name, sim_path = find_simulator()

if simulator_name is None:
    print("ERROR: No simulator found.")
    print("  Checked: Vivado XSim (xvlog/xsim on PATH),")
    print("           GHDL (C:\\GIT\\ghdl-mcode-6.0.0-rc2-mingw64\\bin),")
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
    vu.set_compile_option("vivado.xvhdl_flags", ["-relax"])
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
