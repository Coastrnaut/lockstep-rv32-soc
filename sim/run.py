import os
from pathlib import Path
from vunit import VUnit

# ==============================================================================
# VUnit Test Runner — lockstep-rv32-soc RISC-V SoC
# ==============================================================================
# Runs the full regression matrix against GHDL. Enables code coverage tracking
# for ASIL-D compliance reporting.
#
# Usage:
#   python sim/run.py --compile    # Compile only
#   python sim/run.py             # Run all tests
#   python sim/run.py --test <name>  # Run a single test
# ==============================================================================

# Pin GHDL executable — Windows absolute path, Linux falls back to PATH
if os.name == "nt":  # Windows
    GHDL_BIN = r"C:\GIT\ghdl-mcode-6.0.0-rc2-mingw64\bin"
    if os.path.isdir(GHDL_BIN):
        os.environ["VUNIT_GHDL_PATH"] = GHDL_BIN
    else:
        print(f"WARNING: GHDL bin not found at {GHDL_BIN} — will use PATH fallback")
# On Linux (CI runner), ghdl is installed via apt and found on PATH

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
# 7. GHDL flags (coverage removed — GHDL 6.0 mcode backend lacks coverage)
# ---------------------------------------------------------------------------
# vu.set_sim_option("ghdl.sim_flags", [...])

# ---------------------------------------------------------------------------
# 8. Run
# ---------------------------------------------------------------------------
vu.main()
