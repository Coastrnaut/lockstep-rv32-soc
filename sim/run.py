from pathlib import Path
from vunit import VUnit

# ==============================================================================
# VUnit Test Runner — ASIL-V Lockstep RISC-V SoC
# ==============================================================================
# Runs the full regression matrix against GHDL. Enables code coverage tracking
# for ASIL-D compliance reporting.
#
# Usage:
#   python3 sim/run.py --compile    # Compile only
#   python3 sim/run.py             # Run all tests
#   python3 sim/run.py --test <name>  # Run a single test
# ==============================================================================

# Initialize VUnit testing context
vu = VUnit.from_argv()
vu.add_vhdl_2008()

# Resolve paths relative to this script
root = Path(__file__).parent.parent

# ---------------------------------------------------------------------------
# 1. Custom types package (must compile first — other files depend on it)
# ---------------------------------------------------------------------------
work_lib = vu.add_library("work")
work_lib.add_source_files(root / "config" / "package_soc_types.vhd")

# ---------------------------------------------------------------------------
# 2. Safety blocks
# ---------------------------------------------------------------------------
work_lib.add_source_files(root / "rtl" / "safety_blocks" / "*.vhd")

# ---------------------------------------------------------------------------
# 3. Peripherals
# ---------------------------------------------------------------------------
work_lib.add_source_files(root / "rtl" / "peripherals" / "*.vhd")

# ---------------------------------------------------------------------------
# 4. NEORV32 submodule (compile into its own library)
# ---------------------------------------------------------------------------
neorv32_lib = vu.add_library("neorv32")
neorv32_rtl = root / "rtl" / "core" / "neorv32" / "rtl" / "core"
if neorv32_rtl.exists():
    neorv32_lib.add_source_files(str(neorv32_rtl) + "/*.vhd")
else:
    print("WARNING: NEORV32 RTL not found at", neorv32_rtl)
    print("  Run: git submodule update --init --recursive")

# ---------------------------------------------------------------------------
# 5. Top-level SoC
# ---------------------------------------------------------------------------
work_lib.add_source_files(root / "rtl" / "top_automotive_soc.vhd")

# ---------------------------------------------------------------------------
# 6. Testbenches
# ---------------------------------------------------------------------------
sim_lib = vu.add_library("sim_lib")
sim_lib.add_source_files(root / "sim" / "testbenches" / "*.vhd")

# ---------------------------------------------------------------------------
# 7. GHDL coverage flags (mandatory for ASIL-D compliance)
# ---------------------------------------------------------------------------
vu.set_sim_option("ghdl.sim_options", [
    "--coverage-signals",
    "--coverage-statements",
    "--coverage-asserts",
    "--coverage-fsm",
    "--coverage-branches",
])

# ---------------------------------------------------------------------------
# 8. Run
# ---------------------------------------------------------------------------
vu.main()
