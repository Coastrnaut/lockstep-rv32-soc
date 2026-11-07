#!/usr/bin/env python3
"""Mutation campaign: does the regression notice when the RTL is wrong?

Each mutant breaks one rule in the RTL through regex substitutions on the
source text. A strong regression fails at least one test for every mutant. A
mutant that survives marks a rule that no test checks. Code coverage cannot
show that: it says a line ran, not that any test would notice the line change.

The campaign copies config/, rtl/ and sim/ to a temporary directory and never
touches the working tree. The unmutated copy must pass first. Each mutant then
meets the quick benches, and the full regression only if it gets past them.
The lint gates are off (LOCKSTEP_NO_LINT), because a mutant can be legal VHDL
that breaks a style rule, and it still has to reach the tests.

    python sim/scripts/mutate.py                every mutant
    python sim/scripts/mutate.py ecc: ram:      those whose name contains any of these
    python sim/scripts/mutate.py --check        do the patterns still match? runs nothing
    python sim/scripts/mutate.py --list         print the names
    python sim/scripts/mutate.py --shard 2/6    every sixth mutant, from the second

Each mutant gets one line:

    [killed ] name: N test(s) in benches   at least one test failed
    [SURVIVE] name                         every test passed: a test is missing
    [NOFAIL ] name: ...                    run.py failed, but no test did
    [TIMEOUT] name                         the run took longer than --timeout
    [COMPILE] name: ...                    the mutant does not compile
    [SKIP   ] name: ...                    the pattern no longer matches the RTL

A COMPILE or NOFAIL result is retried once from a clean build. The exit status
is 0 only when every mutant was killed. A full campaign takes hours of CPU, so
it runs before a release and after RTL changes rather than on every push.
--shard splits one across processes, each in its own copy.

MUTATE_REPO, MUTATE_P, MUTATE_FAST, MUTATE_LIST and MUTATE_NO_BASELINE give
the defaults for --repo, --jobs, --fast, --names-file and --no-baseline.

Patterns see the source with CRLF turned into LF, and the mutated file is
written with LF. vsg realigning code can leave a pattern stale: --check finds
those.
"""
import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

LOCK = "rtl/safety_blocks/lockstep_comparator.vhd"
WDT = "rtl/safety_blocks/hardware_watchdog.vhd"
UART = "rtl/peripherals/safe_uart.vhd"
CAN = "rtl/peripherals/automotive_can_controller.vhd"
PKG = "config/package_soc_types.vhd"
TOP = "rtl/top_automotive_soc.vhd"
RST = "rtl/safety_blocks/reset_synchronizer.vhd"
ECC = "rtl/safety_blocks/hamming_ecc_wrapper.vhd"
RAM = "rtl/safety_blocks/ecc_data_ram.vhd"
SKEW = "rtl/safety_blocks/temporal_diversity.vhd"
TEST = "rtl/safety_blocks/comparator_self_test.vhd"
RX = "rtl/peripherals/can_receiver.vhd"
SUP = "rtl/safety_blocks/watchdog_supervisor.vhd"

CLEAR = r"w_tx_clear <= '1' when \(rst_n_i = '0' or bus_ok_i = '0' or r_bus_off = '1'\) else"


def constant(name, old, new):
    """Change the value in a to_unsigned(value, width) constant declaration."""
    return [(rf"({name}\s*: unsigned\([0-9]+ downto 0\) := to_unsigned\(){old},", rf"\g<1>{new},")]


def natural(name, old, new):
    return [(rf"({name}\s*: natural := ){old};", rf"\g<1>{new};")]


# (name, file, [(pattern, replacement), ...])
MUTANTS = [
    ("lockstep: mismatch never detected", LOCK, [(r"w_mismatch_detected <= '1';", "w_mismatch_detected <= '0';")]),
    ("lockstep: bus not gated on fault", LOCK,
     [(r"bus_valid_o  <= '1' when \(r_current_state = ST_SYSTEM_OK\) else\s+'0';", "bus_valid_o  <= '1';")]),
    ("watchdog: early kick ignored", WDT,
     [(r"(-- Early kick: CPU is running too fast / loop too tight\s+)r_timeout_latched <= '1';", r"\1null;")]),
    ("uart: safety gate ignored on write", UART,
     [(r"elsif \(bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '1' and bus_i.sel\(0\)",
       "elsif (bus_i.valid = '1' and bus_i.we = '1' and bus_i.sel(0)")]),

    # --- Address decode
    ("decode: CAN TX_REQUEST takes any address", CAN,
     [(r"elsif \(bus_i\.addr = c_can_tx_request_addr\) then", "else")]),
    ("decode: CAN TX_REQUEST ignores high address bits", CAN,
     [(r"bus_i\.addr = c_can_tx_request_addr", "bus_i.addr(11 downto 0) = c_can_tx_request_addr(11 downto 0)")]),
    ("decode: CAN TX_REQUEST ignores the top address bit", CAN,
     [(r"bus_i\.addr = c_can_tx_request_addr", "bus_i.addr(30 downto 0) = c_can_tx_request_addr(30 downto 0)")]),
    ("decode: CAN TX_REQUEST ignores byte offset", CAN,
     [(r"bus_i\.addr = c_can_tx_request_addr", "bus_i.addr(31 downto 2) = c_can_tx_request_addr(31 downto 2)")]),
    ("decode: UART takes any address", UART, [(r" and\s+bus_i\.addr = c_uart_tx_data_addr", "")]),
    ("decode: UART ignores high address bits", UART,
     [(r"bus_i\.addr = c_uart_tx_data_addr", "bus_i.addr(11 downto 0) = c_uart_tx_data_addr(11 downto 0)")]),
    ("decode: UART ignores the top address bit", UART,
     [(r"bus_i\.addr = c_uart_tx_data_addr", "bus_i.addr(30 downto 0) = c_uart_tx_data_addr(30 downto 0)")]),
    ("decode: UART ignores byte offset", UART,
     [(r"bus_i\.addr = c_uart_tx_data_addr", "bus_i.addr(31 downto 2) = c_uart_tx_data_addr(31 downto 2)")]),
    ("decode: wrong CAN ID address in the package", PKG, [(r'x"40000300"', 'x"40000320"')]),
    ("decode: wrong CAN DLC address in the package", PKG, [(r'x"40000304"', 'x"40000324"')]),
    ("decode: wrong CAN DATA address in the package", PKG, [(r'x"40000308"', 'x"40000328"')]),
    ("decode: wrong CAN DATA_HI address in the package", PKG, [(r'x"40000310"', 'x"40000330"')]),
    ("decode: wrong CAN TX_REQUEST address in the package", PKG, [(r'x"40000314"', 'x"40000334"')]),
    ("decode: wrong UART address in the package", PKG, [(r'x"40000400"', 'x"40000404"')]),
    ("decode: CAN and UART addresses swapped", PKG,
     [(r'x"40000314"', 'x"TEMP"'), (r'x"40000400"', 'x"40000314"'), (r'x"TEMP"', 'x"40000400"')]),

    # --- CAN registers
    ("regs: ID write drops a bit", CAN, [(r"r_mailbox_id <= bus_i\.data\(10 downto 0\);", "r_mailbox_id <= '0' & bus_i.data(9 downto 0);")]),
    ("regs: DLC write drops a bit", CAN, [(r"r_mailbox_dlc <= unsigned\(bus_i\.data\(3 downto 0\)\);", "r_mailbox_dlc <= unsigned('0' & bus_i.data(2 downto 0));")]),
    ("regs: DATA and DATA_HI swapped", CAN, [(r"r_mailbox_data\(63 downto 32\) <= bus_i\.data;", "r_mailbox_data(31 downto 0) <= bus_i.data;"),
                                            (r"(elsif \(bus_i\.addr = c_can_data_hi_addr\) then\s+)r_mailbox_data\(31 downto 0\) <= bus_i\.data;", r"\1r_mailbox_data(63 downto 32) <= bus_i.data;")]),
    ("regs: mailbox not locked while pending", CAN, [(r'bus_i\.sel = "1111" and\s+r_mailbox_full = \'0\'\) else', 'bus_i.sel = "1111") else')]),
    ("regs: frame sent without TX_REQUEST", CAN, [(r"r_mailbox_data\(63 downto 32\) <= bus_i\.data;", "r_mailbox_data(63 downto 32) <= bus_i.data;\n          r_mailbox_full <= '1';")]),
    ("regs: contents lost after a frame", CAN, [(r"elsif \(w_frame_done = '1'\) then\s+r_mailbox_full <= '0';", "elsif (w_frame_done = '1') then\n        r_mailbox_full <= '0';\n        r_mailbox_id   <= (others => '0');")]),
    ("regs: gate drop keeps the mailbox", CAN, [(r"if \(w_tx_clear = '1'\) then(\s+)r_mailbox_id   <= \(others => '0'\);\s+r_mailbox_dlc  <= \(others => '0'\);\s+r_mailbox_data <= \(others => '0'\);", r"if (w_tx_clear = '1') then\1null;")]),
    ("regs: ID reads back wrong", CAN, [(r"r_rdata\(10 downto 0\) <= r_mailbox_id;", "null;")]),
    ("regs: DLC reads back wrong", CAN, [(r"r_rdata\(3 downto 0\) <= std_logic_vector\(r_mailbox_dlc\);", "null;")]),
    ("regs: DATA reads back wrong", CAN, [(r"r_rdata <= r_mailbox_data\(63 downto 32\);", "r_rdata <= r_mailbox_data(31 downto 0);")]),
    ("regs: DATA_HI reads back wrong", CAN, [(r"r_rdata <= r_mailbox_data\(31 downto 0\);", "null;")]),

    # --- Read path
    ("read: wrong CAN STATUS address in the package", PKG, [(r'x"4000030C"', 'x"40000310"')]),
    ("read: wrong UART STATUS address in the package", PKG, [(r'x"40000404"', 'x"4000040C"')]),
    ("read: wrong UART PARITY address in the package", PKG, [(r'x"40000408"', 'x"4000040C"')]),
    ("read: CAN data not cleared after a read", CAN,
     [(r"r_rdata <= \(others => '0'\);\n\n      if \(rst_n_i = '1'", "if (rst_n_i = '1'")]),
    ("read: UART data not cleared after a read", UART,
     [(r"r_rdata <= \(others => '0'\);\n\n      if \(rst_n_i = '1'", "if (rst_n_i = '1'")]),
    ("read: CAN read ignores the gate", CAN, [(r"if \(rst_n_i = '1' and bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '0'\)",
                                               "if (rst_n_i = '1' and bus_i.valid = '1' and bus_i.we = '0')")]),
    ("read: UART read ignores the gate", UART, [(r"if \(rst_n_i = '1' and bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '0'",
                                                 "if (rst_n_i = '1' and bus_i.valid = '1' and bus_i.we = '0'")]),
    ("read: CAN ignores high address bits", CAN,
     [(r"elsif \(bus_i\.addr = c_can_status_addr\) then", "elsif (bus_i.addr(11 downto 0) = c_can_status_addr(11 downto 0)) then")]),
    ("irq: CAN clear ignores high address bits", CAN,
     [(r"bus_i\.addr = c_can_status_addr\) else", "bus_i.addr(11 downto 0) = c_can_status_addr(11 downto 0)) else")]),
    ("irq: UART clear ignores high address bits", UART,
     [(r"bus_i\.we = '1' and bus_i\.addr = c_uart_status_addr\)", "bus_i.we = '1' and bus_i.addr(11 downto 0) = c_uart_status_addr(11 downto 0))")]),
    ("read: UART STATUS ignores high address bits", UART,
     [(r"bus_i\.addr = c_uart_status_addr", "bus_i.addr(11 downto 0) = c_uart_status_addr(11 downto 0)")]),
    ("read: UART PARITY ignores high address bits", UART,
     [(r"bus_i\.addr = c_uart_parity_addr", "bus_i.addr(11 downto 0) = c_uart_parity_addr(11 downto 0)")]),
    ("read: CAN TEC field moved", CAN, [(r"r_rdata\(16 downto 8\)", "r_rdata(15 downto 7)")]),
    ("read: CAN busy bit lost", CAN, [(r"r_rdata\(0\)\s+<= w_busy;", "null;")]),
    ("read: CAN passive bit lost", CAN, [(r"r_rdata\(1\)\s+<= w_error_passive;", "null;")]),
    ("read: CAN bus-off bit lost", CAN, [(r"r_rdata\(2\)\s+<= r_bus_off;", "null;")]),
    ("read: UART busy bit lost", UART, [(r"r_rdata\(0\) <= w_busy;", "null;")]),
    ("read: UART parity bit lost", UART, [(r"r_rdata\(0\) <= w_parity_ok;", "null;")]),

    # --- Top-level wiring, which only the firmware bench reaches
    ("top: NMI pin not driven", TOP, [(r"  nmi_fault_o <= \(w_nmi and w_self_test_passed\) or w_self_test_failed;\n", "  nmi_fault_o <= '0';\n")]),
    ("top: core A gets no read data", TOP, [(r"xbus_dat_i => w_core_a_in\.rdata", "xbus_dat_i => (others => '0')")]),
    ("top: core B gets no read data", TOP, [(r"xbus_dat_i => w_core_b_in\.rdata", "xbus_dat_i => (others => '0')")]),
    ("top: UART read data dropped", TOP, [(r"w_periph_rdata <= w_can_rdata or w_uart_rdata or w_wd_rdata or w_ram_rdata;", "w_periph_rdata <= w_can_rdata or w_wd_rdata or w_ram_rdata;")]),
    ("top: CAN read data dropped", TOP, [(r"w_periph_rdata <= w_can_rdata or w_uart_rdata or w_wd_rdata or w_ram_rdata;", "w_periph_rdata <= w_uart_rdata or w_wd_rdata or w_ram_rdata;")]),
    ("top: checker core boots elsewhere", TOP, [(r"(boot_mode_select => g_boot_mode.*?)boot_mode_select => g_boot_mode", r"\1boot_mode_select => 0")]),

    # --- Byte enables, and each field the comparator checks
    ("sel: comparator ignores byte enables", LOCK, [(r"\(core_a_bus_i\.sel /= core_b_bus_i\.sel\)", "(false and core_a_bus_i.sel /= core_b_bus_i.sel)")]),
    ("sel: comparator ignores addr", LOCK, [(r"\(core_a_bus_i\.addr /= core_b_bus_i\.addr\)", "(false and core_a_bus_i.addr /= core_b_bus_i.addr)")]),
    ("sel: comparator ignores data", LOCK, [(r"\(core_a_bus_i\.data /= core_b_bus_i\.data\)", "(false and core_a_bus_i.data /= core_b_bus_i.data)")]),
    ("sel: comparator ignores we", LOCK, [(r"\(core_a_bus_i\.we /= core_b_bus_i\.we\)", "(false and core_a_bus_i.we /= core_b_bus_i.we)")]),
    ("sel: comparator ignores valid", LOCK, [(r"\(core_a_bus_i\.valid /= core_b_bus_i\.valid\)", "(false and core_a_bus_i.valid /= core_b_bus_i.valid)")]),
    ("sel: not gated on a fault", LOCK, [(r"sys_bus_o\.sel   <= core_a_bus_i\.sel when \(w_bus_open = '1'\) else\s+\(others => '0'\);", "sys_bus_o.sel   <= core_a_bus_i.sel;")]),
    ("sel: CAN takes partial stores", CAN, [(r' and bus_i\.sel = "1111"', "")]),
    ("sel: UART takes stores without byte 0", UART, [(r" and bus_i\.sel\(0\) = '1'", "")]),
    ("sel: UART wants a whole word", UART, [(r"bus_i\.sel\(0\) = '1'", 'bus_i.sel = "1111"')]),
    ("sel: top level drops core A byte enables", TOP, [(r"w_core_a_bus\.sel   <= w_core_a_xbus_sel;", 'w_core_a_bus.sel   <= "1111";')]),
    ("sel: top level drops core B byte enables", TOP, [(r"w_core_b_bus\.sel   <= w_core_b_xbus_sel;", 'w_core_b_bus.sel   <= "1111";')]),

    # --- UART serialiser
    ("uart: shift register does not shift", UART, [(r"r_tx_shift <= '1' & r_tx_shift\(10 downto 1\);", "r_tx_shift <= r_tx_shift(10 downto 1) & '1';")]),
    ("uart: stop bit not loaded", UART, [(r"r_tx_shift\(10\)\s+<= '1';\s+-- stop bit", "")]),
    ("uart: parity sent inverted", UART, [(r"r_tx_shift\(9\)\s+<= r_tx_parity;", "r_tx_shift(9) <= not r_tx_parity;")]),
    ("uart: start bit recessive", UART, [(r"r_tx_shift\(0\)\s+<= '0';\s+-- start bit", "r_tx_shift(0) <= '1';")]),
    ("uart: bit one clock long", UART, [(r"if \(r_baud_cnt >= c_baud_div - 1\) then", "if (r_baud_cnt >= c_baud_div) then")]),
    ("uart: one bit too few", UART, [(r'r_tx_bits\s+<= "1010";', 'r_tx_bits <= "1001";')]),

    # --- CRC
    # --- Error interrupts
    ("irq: CAN flag never set", CAN, [(r"r_error_irq <= '1';", "null;")]),
    ("irq: CAN read clears it", CAN, [(r"w_status_write <= '1' when \(bus_ok_i = '1' and bus_i\.valid = '1' and bus_i\.we = '1' and", "w_status_write <= '1' when (bus_ok_i = '1' and bus_i.valid = '1' and")]),
    ("irq: CAN any address clears it", CAN, [(r'bus_i\.sel = "1111" and\s+bus_i\.addr = c_can_status_addr\) else', 'bus_i.sel = "1111") else')]),
    ("irq: CAN partial store clears it", CAN, [(r'w_status_write <= (.*?)bus_i\.sel = "1111" and', r"w_status_write <= \1")]),
    ("irq: CAN clear ignores the gate", CAN, [(r"w_status_write <= '1' when \(bus_ok_i = '1' and ", "w_status_write <= '1' when (")]),
    ("irq: CAN clear beats a failure", CAN, [(r"if \(w_tx_fail = '1'\) then\s+r_error_irq <= '1';\s+elsif \(w_status_write = '1'\) then\s+r_error_irq <= '0';", "if (w_status_write = '1') then r_error_irq <= '0'; elsif (w_tx_fail = '1') then r_error_irq <= '1';")]),
    ("irq: CAN STATUS does not show it", CAN, [(r"r_rdata\(3\)\s+<= r_error_irq;", "r_rdata(3) <= '0';")]),
    ("irq: CAN arbitration loss raises it", CAN, [(r"if \(w_tx_fail = '1'\) then\s+r_error_irq <= '1';", "if (w_tx_fail = '1' or r_arb_lost = '1') then r_error_irq <= '1';")]),
    ("irq: CAN flag has no reset", CAN, [(r"r_error_irq     <= '0';\n", "\n")]),
    ("irq: CAN pin stuck low", CAN, [(r"can_irq_o <= r_error_irq or \(r_buf_full and r_buf_irq_en\);", "can_irq_o <= r_buf_full and r_buf_irq_en;")]),
    ("irq: UART flag never set", UART, [(r"elsif \(w_error = '1'\) then\s+r_error_irq <= '1';", "elsif (false) then null;")]),
    ("irq: UART read clears it", UART, [(r"elsif \(bus_ok_i = '1' and bus_i\.valid = '1' and bus_i\.we = '1' and bus_i\.addr = c_uart_status_addr\)", "elsif (bus_ok_i = '1' and bus_i.valid = '1' and bus_i.addr = c_uart_status_addr)")]),
    ("irq: UART any address clears it", UART, [(r"bus_i\.we = '1' and bus_i\.addr = c_uart_status_addr\)", "bus_i.we = '1')")]),
    ("irq: UART clear ignores the gate", UART, [(r"elsif \(bus_ok_i = '1' and (bus_i\.valid = '1' and bus_i\.we = '1' and bus_i\.addr = c_uart_status_addr\))", r"elsif (\1")]),
    ("irq: UART clear beats an error", UART, [(r"elsif \(w_error = '1'\) then\s+r_error_irq <= '1';\s+elsif \(bus_ok_i = '1' and bus_i\.valid = '1' and bus_i\.we = '1' and bus_i\.addr = c_uart_status_addr\) then\s+r_error_irq <= '0';", "elsif (bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '1' and bus_i.addr = c_uart_status_addr) then r_error_irq <= '0'; elsif (w_error = '1') then r_error_irq <= '1';")]),
    ("irq: UART STATUS shows only the pulse", UART, [(r"r_rdata\(1\) <= r_error_irq;", "r_rdata(1) <= w_error;")]),
    ("irq: UART flag has no reset", UART, [(r"r_error_irq <= '0';\s+elsif \(w_error", "null; elsif (w_error")]),
    ("irq: UART pin stuck low", UART, [(r"uart_irq_o <= r_error_irq;", "uart_irq_o <= '0';")]),
    ("irq: core A misses CAN_ERROR", TOP, [(r"irq_msi_i => w_core_a_in\.msi", "irq_msi_i => '0'")]),
    ("irq: core B misses CAN_ERROR", TOP, [(r"irq_msi_i => w_core_b_in\.msi", "irq_msi_i => '0'")]),
    ("irq: core A misses UART_ERROR", TOP, [(r"irq_mti_i => w_core_a_in\.mti", "irq_mti_i => '0'")]),
    ("irq: core B misses UART_ERROR", TOP, [(r"irq_mti_i => w_core_b_in\.mti", "irq_mti_i => '0'")]),
    ("irq: lines swapped on both cores", TOP, [(r"w_core_a_in\.msi   <= w_can_irq;", "w_core_a_in.msi   <= w_uart_irq;"), (r"w_core_a_in\.mti   <= w_uart_irq;", "w_core_a_in.mti   <= w_can_irq;")]),
    ("uart: parity gate bypassed", UART, [(r"if \(r_tx_valid = '1' and w_parity_ok = '1'\) then", "if (r_tx_valid = '1') then")]),
    ("uart: parity error not reported", UART, [(r"w_error <= '1' when \(r_tx_valid = '1' and w_parity_ok = '0'\) else", "w_error <= '1' when (false) else")]),
    ("uart: PARITY register stuck good", UART, [(r"r_rdata\(0\) <= w_parity_ok;", "r_rdata(0) <= '1';")]),

    # --- Reset network
    ("reset: released a stage early", RST, [(r"rst_n_syn_o <= r_stages\(g_stages - 1\);", "rst_n_syn_o <= r_stages(g_stages - 2);")]),
    ("reset: released on the falling edge", RST, [(r"elsif rising_edge\(clk_i\) then\s+r_stages", "elsif falling_edge(clk_i) then r_stages")]),
    ("reset: needs a clock to assert", RST, [(r"process \(clk_i, rst_n_i\)", "process (clk_i)"), (r"if \(rst_n_i = '0'\) then\s+r_stages <= \(others => '0'\);\s+elsif rising_edge\(clk_i\) then\s+r_stages <= r_stages\(g_stages - 2 downto 0\) & '1';\s+end if;", "if rising_edge(clk_i) then if (rst_n_i = '0') then r_stages <= (others => '0'); else r_stages <= r_stages(g_stages - 2 downto 0) & '1'; end if; end if;")]),
    ("reset: only the first stage cleared", RST, [(r"r_stages <= \(others => '0'\);", "r_stages(0) <= '0';")]),
    ("reset: core A on the raw reset", TOP, [(r"rstn_i     => w_core_a_in\.rst_n", "rstn_i     => rst_n_i")]),
    ("reset: both cores on the raw reset", TOP, [(r"w_core_a_in\.rst_n <= w_rst_n;", "w_core_a_in.rst_n <= rst_n_i;")]),
    ("reset: core B on the raw reset", TOP, [(r"rstn_i     => w_core_b_in\.rst_n", "rstn_i     => rst_n_i")]),
    ("reset: comparator on the raw reset", TOP, [(r"rst_n_i       => w_cold_rst_n,\s+flip_bus_o", "rst_n_i       => rst_n_i,\n      flip_bus_o")]),
    ("reset: CAN on the raw reset", TOP, [(r"(i_automotive_can.*?rst_n_i      => )w_rst_n", r"\g<1>rst_n_i")]),
    ("reset: UART on the raw reset", TOP, [(r"(i_safe_uart.*?rst_n_i      => )w_rst_n", r"\g<1>rst_n_i")]),
    ("reset: actuators not held safe", TOP, [(r"actuator_safe_o <= w_lockstep_safe or not w_rst_n;", "actuator_safe_o <= w_lockstep_safe;")]),
    ("reset: actuators held safe by the raw reset only", TOP, [(r"actuator_safe_o <= w_lockstep_safe or not w_rst_n;", "actuator_safe_o <= w_lockstep_safe or not rst_n_i;")]),
    ("reset: lockstep fault does not reach the actuators", TOP, [(r"actuator_safe_o <= w_lockstep_safe or not w_rst_n;", "actuator_safe_o <= not w_rst_n;")]),

    # --- Watchdog in the SoC
    ("wd: kick ignores the key", SUP, [(r" and bus_i\.data = c_wd_kick_key\) else", ") else")]),
    ("wd: kick ignores the address", SUP, [(r"bus_i\.addr = c_wd_kick_addr and ", "")]),
    ("wd: kick ignores the top address bits", SUP, [(r"bus_i\.addr = c_wd_kick_addr and", "bus_i.addr(11 downto 0) = c_wd_kick_addr(11 downto 0) and")]),
    ("wd: kick takes a partial store", SUP, [(r'and bus_i\.sel = "1111" and', "and")]),
    ("wd: kick ignores the gate", SUP, [(r"w_kick_write <= '1' when \(bus_ok_i = '1' and ", "w_kick_write <= '1' when (")]),
    ("wd: read counts as a kick", SUP, [(r"bus_i\.valid = '1' and bus_i\.we = '1' and bus_i\.sel", "bus_i.valid = '1' and bus_i.sel")]),
    ("wd: kick needs no strobe", SUP, [(r"bus_ok_i = '1' and bus_i\.valid = '1' and bus_i\.we = '1' and bus_i\.sel", "bus_ok_i = '1' and bus_i.we = '1' and bus_i.sel")]),
    ("wd: kick wider than one clock", SUP, [(r"w_kick <= r_kick_sync\(1\) and not r_kick_sync\(2\);", "w_kick <= r_kick_sync(1);")]),
    ("wd: kick request never drops", SUP, [(r"elsif \(r_kick_ack\(1\) = '1'\) then\s+r_kick_req <= '0';", "elsif (r_kick_ack(1) = '1') then null;")]),
    ("wd: reset pulse never ends", SUP, [(r"r_reset     <= '0';\s+r_reset_cnt <= \(others => '0'\);\s+end if;\s+elsif", "null; end if; elsif")]),
    ("wd: reset pulse a clock short", SUP, [(r"to_unsigned\(16, 5\)", "to_unsigned(15, 5)")]),
    ("wd: reset pulse a clock long", SUP, [(r"to_unsigned\(16, 5\)", "to_unsigned(17, 5)")]),
    ("wd: early shown as late", SUP, [(r"r_reset_src <= c_src_early;", "r_reset_src <= c_src_late;")]),
    ("wd: late shown as early", SUP, [(r"r_reset_src <= c_src_late;", "r_reset_src <= c_src_early;")]),
    ("wd: watchdog not restarted", SUP, [(r"w_wd_rst_n <= wd_rst_n_i and not r_reset;", "w_wd_rst_n <= wd_rst_n_i;")]),
    ("wd: status never crosses", SUP, [(r"r_status_sys <= r_status_wd;", "null;")]),
    ("wd: status taken before an answer", SUP, [(r"r_status_req <= '1';", "r_status_req <= '0';")]),
    ("wd: status read ignores the gate", SUP, [(r"rst_n_i = '1' and bus_ok_i = '1' and bus_i\.valid", "rst_n_i = '1' and bus_i.valid")]),
    ("wd: status read ignores the top address bits", SUP, [(r"if \(bus_i\.addr = c_wd_status_addr\) then", "if (bus_i.addr(11 downto 0) = c_wd_status_addr(11 downto 0)) then")]),
    ("wd: writes read back", SUP, [(r"bus_i\.valid = '1' and bus_i\.we = '0'\) then", "bus_i.valid = '1') then")]),
    ("wd: unknown level on a dead oscillator", SUP, [(r"sys_reset_o <= r_reset and wd_rst_n_i;", "sys_reset_o <= r_reset;")]),
    ("wd: comparator cleared by a watchdog reset", TOP, [(r"rst_n_syn_i => w_comparator_rst_n", "rst_n_syn_i => w_rst_n")]),
    ("wd: watchdog does not reset the SoC", TOP, [(r"w_rst_n_request <= w_cold_rst_n and w_self_test_passed and not w_wd_reset;", "w_rst_n_request <= w_cold_rst_n and w_self_test_passed;")]),
    ("wd: supervisor cleared by its own reset", TOP, [(r"(i_watchdog_supervisor.*?rst_n_i     => )w_cold_rst_n", r"\g<1>w_rst_n")]),
    ("wd: oscillator side cleared by its own reset", TOP, [(r"(i_wd_reset_sync.*?rst_n_i     => )rst_n_i", r"\g<1>w_rst_n_request")]),
    ("wd: runs from the system clock", TOP, [(r"(i_watchdog_supervisor.*?wd_clk_i    => )wd_clk_i", r"\g<1>clk_i")]),
    ("wd: reset synchroniser runs from the system clock", TOP, [(r"(i_wd_reset_sync.*?clk_i       => )wd_clk_i", r"\g<1>clk_i")]),
    ("wd: status does not reach the cores", TOP, [(r"w_periph_rdata <= w_can_rdata or w_uart_rdata or w_wd_rdata or w_ram_rdata;", "w_periph_rdata <= w_can_rdata or w_uart_rdata or w_ram_rdata;")]),
    ("wd: wrong key", PKG, [(r'x"0000DEAD"', 'x"0000DEAE"')]),

    # --- ECC code
    ("ecc: data bits start at position 0", ECC, [(r"v_position   := 3;", "v_position   := 0;")]),
    ("ecc: data bits share check bit positions", ECC, [(r"if \(v_position = v_next_check\) then", "if (false) then")]),
    ("ecc: a flipped check bit changes data", ECC, [(r"elsif \(\(unsigned\(v_syndrome\) and \(unsigned\(v_syndrome\) - 1\)\) = 0\) then", "elsif (v_syndrome = \"0000000\") then")]),
    ("ecc: a flipped P7 goes unreported", ECC, [(r"(elsif \(\(unsigned\(v_syndrome\) and \(unsigned\(v_syndrome\) - 1\)\) = 0\) then.*?)w_sbe <= '1';", r"\1null;")]),
    ("ecc: double flips not fatal", ECC, [(r"if \(v_syndrome /= \"0000000\"\) then\s+w_dbe <= '1';", "if (v_syndrome /= \"0000000\") then\n        null;")]),
    ("ecc: three flips not fatal", ECC, [(r"(which takes three or more flips\s+)w_dbe <= '1';", r"\1null;")]),
    ("ecc: located bit not flipped", ECC, [(r"w_corrected_data\(j\) <= not data_rd_i\(j\);", "w_corrected_data(j) <= data_rd_i(j);")]),
    ("ecc: correction still fatal", ECC, [(r"w_sbe               <= '1';\s+w_dbe               <= '0';", "w_sbe               <= '1';")]),
    ("ecc: P7 misses the check bits", ECC, [(r"for i in 0 to 6 loop\s+if \(v_parity\(i\) = '1'\) then\s+v_parity_count := v_parity_count \+ 1;\s+end if;\s+end loop;", "")]),
    ("ecc: top check bit stuck low", ECC, [(r"ecc_o\(6 downto 0\) <= v_parity;", "ecc_o(6 downto 0) <= '0' & v_parity(5 downto 0);")]),

    # --- ECC protected RAM
    ("ram: every address selected", RAM, [(r" and\s+bus_i\.addr\(c_addr_width - 1 downto g_addr_bits \+ 3\) =\s+c_ram_base_addr\(c_addr_width - 1 downto g_addr_bits \+ 3\)\)", ")")]),
    ("ram: top address bit ignored", RAM, [(r"bus_i\.addr\(c_addr_width - 1 downto g_addr_bits \+ 3\) =\s+c_ram_base_addr\(c_addr_width - 1 downto g_addr_bits \+ 3\)", "bus_i.addr(c_addr_width - 2 downto g_addr_bits + 3) = c_ram_base_addr(c_addr_width - 2 downto g_addr_bits + 3)")]),
    ("ram: lowest decoded address bit ignored", RAM, [(r"bus_i\.addr\(c_addr_width - 1 downto g_addr_bits \+ 3\) =\s+c_ram_base_addr\(c_addr_width - 1 downto g_addr_bits \+ 3\)", "bus_i.addr(c_addr_width - 1 downto g_addr_bits + 4) = c_ram_base_addr(c_addr_width - 1 downto g_addr_bits + 4)")]),
    ("ram: access ignores the gate", RAM, [(r"w_selected <= '1' when \(bus_ok_i = '1' and ", "w_selected <= '1' when (")]),
    ("ram: store lands when the gate closes", RAM, [(r"if \(r_write = '1' and bus_ok_i = '1' and w_dbe = '0'\) then", "if (r_write = '1' and w_dbe = '0') then")]),
    ("ram: store writes over an uncorrectable word", RAM, [(r"if \(r_write = '1' and bus_ok_i = '1' and w_dbe = '0'\) then", "if (r_write = '1' and bus_ok_i = '1') then")]),
    ("ram: byte enables ignored", RAM, [(r"if \(r_sel\(i\) = '1'\) then", "if (true) then")]),
    ("ram: stores go to the wrong half", RAM, [(r"if \(r_upper = '1'\) then\s+v_low := v_low \+ 32;", "if (r_upper = '0') then\n        v_low := v_low + 32;")]),
    ("ram: loads come from the wrong half", RAM, [(r"w_corrected\(63 downto 32\) when \(r_upper = '1'\) else", "w_corrected(63 downto 32) when (r_upper = '0') else")]),
    ("ram: loads are not corrected", RAM, [(r"w_corrected\(63 downto 32\) when \(r_upper = '1'\) else\s+w_corrected\(31 downto 0\);", "r_word(63 downto 32) when (r_upper = '1') else r_word(31 downto 0);")]),
    ("ram: stores do not repair the word", RAM, [(r"v_word := w_corrected;", "v_word := r_word(63 downto 0);")]),
    ("ram: uncorrectable word returned", RAM, [(r"when \(r_read = '0' or w_dbe = '1'\) else", "when (r_read = '0') else")]),
    ("ram: read data when not reading", RAM, [(r"\(others => '0'\) when \(r_read = '0' or w_dbe = '1'\) else", "(others => '0') when (w_dbe = '1') else")]),
    ("ram: store keeps the old check bits", RAM, [(r":= w_merged_ecc & w_merged;", ":= r_word(71 downto 64) & w_merged;")]),
    ("ram: errors counted outside an access", RAM, [(r"w_sbe <= w_sbe_found and \(r_read or r_write\);", "w_sbe <= w_sbe_found;")]),
    ("ram: fatal outside an access", RAM, [(r"w_dbe <= w_dbe_found and \(r_read or r_write\);", "w_dbe <= w_dbe_found;")]),
    ("ram: stores not checked", RAM, [(r"w_dbe <= w_dbe_found and \(r_read or r_write\);", "w_dbe <= w_dbe_found and r_read;")]),
    ("ram: single-bit errors not counted", RAM, [(r"r_sbe_count <= r_sbe_count \+ 1;", "null;")]),
    ("ram: error count wraps", RAM, [(r"if \(r_sbe_count /= x\"FFFF\"\) then", "if (true) then")]),
    ("ram: double-bit errors not counted", RAM, [(r"r_dbe_count  <= r_dbe_count \+ 1;", "null;")]),
    ("ram: status forgets a double-bit error", RAM, [(r"if \(r_status /= c_status_dbe\) then", "if (true) then")]),
    ("ram: syndrome not kept on a single-bit error", RAM, [(r"(elsif \(w_sbe = '1'\) then\s+)r_last_error <= w_syndrome;", r"\1null;")]),
    ("ram: syndrome not kept on a double-bit error", RAM, [(r"(elsif \(w_dbe = '1'\) then\s+)r_last_error <= w_syndrome;", r"\1null;")]),
    ("ram: fatal not raised", RAM, [(r"dbe_fatal_o <= w_dbe;", "dbe_fatal_o <= '0';")]),
    ("ram: registers ignore the gate", RAM, [(r"rst_n_i = '1' and bus_ok_i = '1' and bus_i\.valid = '1' and bus_i\.we = '0'", "rst_n_i = '1' and bus_i.valid = '1' and bus_i.we = '0'")]),
    ("ram: registers read on a write", RAM, [(r"bus_i\.valid = '1' and bus_i\.we = '0'\) then", "bus_i.valid = '1') then")]),
    ("ram: registers ignore the top address bits", RAM, [(r"if \(bus_i\.addr = c_ecc_sbe_count_addr\) then", "if (bus_i.addr(11 downto 0) = c_ecc_sbe_count_addr(11 downto 0)) then")]),
    ("ram: DBE_COUNT and SBE_COUNT swapped", RAM, [(r"r_reg_rdata\(15 downto 0\) <= std_logic_vector\(r_dbe_count\);", "r_reg_rdata(15 downto 0) <= std_logic_vector(r_sbe_count);")]),
    ("ram: errors cleared by a watchdog reset", TOP, [(r"(i_ecc_ram.*?rst_n_i     => )w_cold_rst_n", r"\g<1>w_rst_n")]),
    ("ram: DBE does not reach the comparator", TOP, [(r"fatal_fault_i => w_ecc_fatal or w_test_fatal", "fatal_fault_i => w_test_fatal")]),
    ("ram: read data does not reach the cores", TOP, [(r"w_periph_rdata <= w_can_rdata or w_uart_rdata or w_wd_rdata or w_ram_rdata;", "w_periph_rdata <= w_can_rdata or w_uart_rdata or w_wd_rdata;")]),
    ("ram: at the wrong address", PKG, [(r'c_ram_base_addr       : std_logic_vector\(c_addr_width - 1 downto 0\) := x"20000000"', 'c_ram_base_addr       : std_logic_vector(c_addr_width - 1 downto 0) := x"30000000"')]),
    ("ram: fatal fault does not trip the comparator", LOCK, [(r"w_trip <= w_mismatch_detected or fatal_fault_i;", "w_trip <= w_mismatch_detected;")]),
    ("ram: fatal fault not latched for the NMI", LOCK, [(r"(if \(w_trip = '1'\) then\s+)r_fault_latched <= '1';", r"\1null;")]),
    ("ram: NMI waits for the latch", LOCK, [(r"nmi_fault_o  <= r_fault_latched or w_trip;", "nmi_fault_o  <= r_fault_latched;")]),

    # --- Temporal diversity
    ("skew: core A's bus not held back", SKEW, [(r"core_a_bus_o <= r_bus\(g_cycles\);", "core_a_bus_o <= core_a_bus_i;")]),
    ("skew: core B's inputs not held back", SKEW, [(r"core_b_in_o  <= r_inputs\(g_cycles\);", "core_b_in_o  <= core_a_in_i;")]),
    ("skew: no delay at all", SKEW, [(r"core_a_bus_o <= r_bus\(g_cycles\);", "core_a_bus_o <= core_a_bus_i;"), (r"core_b_in_o  <= r_inputs\(g_cycles\);", "core_b_in_o  <= core_a_in_i;")]),
    ("skew: one clock", SKEW, [(r"g_cycles : positive range 1 to 8 := 2", "g_cycles : positive range 1 to 8 := 1")]),
    ("skew: three clocks", SKEW, [(r"g_cycles : positive range 1 to 8 := 2", "g_cycles : positive range 1 to 8 := 3")]),
    ("skew: comparator sees core A early", TOP, [(r"core_a_bus_i => w_core_a_bus_late", "core_a_bus_i => w_core_a_bus")]),
    ("skew: core B reset not delayed", TOP, [(r"rstn_i     => w_core_b_in\.rst_n", "rstn_i     => w_core_a_in.rst_n")]),
    ("skew: core B read data not delayed", TOP, [(r"xbus_dat_i => w_core_b_in\.rdata", "xbus_dat_i => w_core_a_in.rdata")]),
    ("skew: core B acknowledge not delayed", TOP, [(r"xbus_ack_i => w_core_b_in\.ack", "xbus_ack_i => w_core_a_in.ack")]),
    ("skew: core B MSI not delayed", TOP, [(r"irq_msi_i => w_core_b_in\.msi", "irq_msi_i => w_core_a_in.msi")]),
    ("skew: core B MTI not delayed", TOP, [(r"irq_mti_i => w_core_b_in\.mti", "irq_mti_i => w_core_a_in.mti")]),
    ("skew: core B MEI not delayed", TOP, [(r"irq_mei_i => w_core_b_in\.mei", "irq_mei_i => w_core_a_in.mei")]),
    ("skew: acknowledge with the strobe", TOP, [(r"w_core_a_in\.ack   <= r_bus_ack;", "w_core_a_in.ack   <= w_safe_sys_bus.valid;")]),
    ("skew: acknowledge always high", TOP, [(r"w_core_a_in\.ack   <= r_bus_ack;", "w_core_a_in.ack   <= w_bus_valid;")]),
    ("skew: acknowledge a clock late", TOP, [(r"w_core_a_in\.ack   <= r_bus_ack;", "w_core_a_in.ack   <= r_bus_ack_late;"), (r"r_bus_ack <= w_safe_sys_bus\.valid;", "r_bus_ack <= w_safe_sys_bus.valid; r_bus_ack_late <= r_bus_ack;"), (r"signal r_bus_ack   : std_logic;", "signal r_bus_ack   : std_logic; signal r_bus_ack_late : std_logic;")]),
    ("gate: a bad cycle reaches the system bus", LOCK, [(r"w_bus_open <= '1' when \(r_current_state = ST_SYSTEM_OK and w_trip = '0'\) else", "w_bus_open <= '1' when (r_current_state = ST_SYSTEM_OK) else")]),
    ("gate: state ignored", LOCK, [(r"w_bus_open <= '1' when \(r_current_state = ST_SYSTEM_OK and w_trip = '0'\) else", "w_bus_open <= '1' when (w_trip = '0') else")]),
    ("gate: address passes a bad cycle", LOCK, [(r"sys_bus_o\.addr  <= core_a_bus_i\.addr when \(w_bus_open = '1'\) else\s+\(others => '0'\);", "sys_bus_o.addr  <= core_a_bus_i.addr;")]),
    ("gate: data passes a bad cycle", LOCK, [(r"sys_bus_o\.data  <= core_a_bus_i\.data when \(w_bus_open = '1'\) else\s+\(others => '0'\);", "sys_bus_o.data  <= core_a_bus_i.data;")]),
    ("gate: write enable passes a bad cycle", LOCK, [(r"sys_bus_o\.we    <= core_a_bus_i\.we when \(w_bus_open = '1'\) else\s+'0';", "sys_bus_o.we    <= core_a_bus_i.we;")]),
    ("gate: pin gate follows the compare", LOCK, [(r"bus_valid_o  <= '1' when \(r_current_state = ST_SYSTEM_OK\) else", "bus_valid_o  <= '1' when (w_bus_open = '1') else")]),

    # --- Comparator self-test
    ("test: skips every other line", TEST, [(r"r_lane <= r_lane \+ 1;", "r_lane <= r_lane + 2;")]),
    ("test: starts at the second line", TEST, [(r"(r_settle <= 0;\s+)r_lane   <= 0;", r"\1r_lane   <= 1;")]),
    ("test: stops before the fatal input", TEST, [(r"elsif \(r_lane = c_fatal_lane\) then", "elsif (r_lane = c_fatal_lane - 1) then")]),
    ("test: passes from reset", TEST, [(r"r_result <= st_fault_tripped;", "r_result <= st_system_ok;")]),
    ("test: never passes", TEST, [(r"r_result <= st_system_ok;", "null;")]),
    ("test: passes on any value but the fail code", TEST, [(r"passed_o <= '1' when \(r_result = st_system_ok\) else", "passed_o <= '1' when (r_result /= st_fault_tripped) else")]),
    ("test: NMI not checked", TEST, [(r"if \(nmi_fault_i = '1'\) then\s+r_step <= step_hold;", "if (true) then r_step <= step_hold;")]),
    ("test: hold not checked", TEST, [(r"if \(w_tripped = '1'\) then", "if (true) then")]),
    ("test: recovery not checked", TEST, [(r"if \(w_clean = '0'\) then\s+r_step <= step_done;\s+elsif", "if (false) then r_step <= step_done; elsif")]),
    ("test: clean ignores the NMI", TEST, [(r"w_clean <= '1' when \(nmi_fault_i = '0' and safe_state_i", "w_clean <= '1' when (safe_state_i")]),
    ("test: clean ignores the safe state", TEST, [(r"w_clean <= '1' when \(nmi_fault_i = '0' and safe_state_i = '0' and", "w_clean <= '1' when (nmi_fault_i = '0' and")]),
    ("test: clean ignores the bus gate", TEST, [(r"safe_state_i = '0' and bus_valid_i = '1'\) else", "safe_state_i = '0') else")]),
    ("test: tripped ignores the NMI", TEST, [(r"w_tripped <= '1' when \(nmi_fault_i = '1' and safe_state_i", "w_tripped <= '1' when (safe_state_i")]),
    ("test: tripped ignores the safe state", TEST, [(r"w_tripped <= '1' when \(nmi_fault_i = '1' and safe_state_i = '1' and", "w_tripped <= '1' when (nmi_fault_i = '1' and")]),
    ("test: tripped ignores the bus gate", TEST, [(r"safe_state_i = '1' and bus_valid_i = '0'\) else", "safe_state_i = '1') else")]),
    ("test: comparator not reset between lines", TEST, [(r"rst_n_o <= '0' when \(rst_n_i = '0' or r_step = step_clear\) else", "rst_n_o <= '0' when (rst_n_i = '0') else")]),
    ("test: comparator held in reset", TEST, [(r"rst_n_o <= '0' when \(rst_n_i = '0' or r_step = step_clear\) else", "rst_n_o <= '0' when (rst_n_i = '0' or r_step = step_done) else")]),
    ("test: injects nothing", TEST, [(r"w_inject\(r_lane\) <= '1';", "null;")]),
    ("test: injects every line at once", TEST, [(r"w_inject\(r_lane\) <= '1';", "w_inject <= (others => '1');")]),
    ("test: failure not reported", TEST, [(r"failed_o <= '1' when \(r_step = step_done and r_result /= st_system_ok\) else", "failed_o <= '1' when (false) else")]),
    ("test: reports failure while running", TEST, [(r"failed_o <= '1' when \(r_step = step_done and r_result /= st_system_ok\) else", "failed_o <= '1' when (r_result /= st_system_ok) else")]),
    ("test: cores start without it", TOP, [(r"w_rst_n_request <= w_cold_rst_n and w_self_test_passed and not w_wd_reset;", "w_rst_n_request <= w_cold_rst_n and not w_wd_reset;")]),
    ("test: runs after a watchdog reset", TOP, [(r"(i_comparator_self_test.*?rst_n_i       => )w_cold_rst_n", r"\g<1>w_rst_n")]),
    ("test: address flips not wired", TOP, [(r"w_core_b_compared\.addr  <= w_core_b_bus\.addr xor w_test_flip\.addr;", "w_core_b_compared.addr  <= w_core_b_bus.addr;")]),
    ("test: data flips not wired", TOP, [(r"w_core_b_compared\.data  <= w_core_b_bus\.data xor w_test_flip\.data;", "w_core_b_compared.data  <= w_core_b_bus.data;")]),
    ("test: byte enable flips not wired", TOP, [(r"w_core_b_compared\.sel   <= w_core_b_bus\.sel xor w_test_flip\.sel;", "w_core_b_compared.sel   <= w_core_b_bus.sel;")]),
    ("test: write enable flip not wired", TOP, [(r"w_core_b_compared\.we    <= w_core_b_bus\.we xor w_test_flip\.we;", "w_core_b_compared.we    <= w_core_b_bus.we;")]),
    ("test: strobe flip not wired", TOP, [(r"w_core_b_compared\.valid <= w_core_b_bus\.valid xor w_test_flip\.valid;", "w_core_b_compared.valid <= w_core_b_bus.valid;")]),
    ("test: fatal input not wired", TOP, [(r"fatal_fault_i => w_ecc_fatal or w_test_fatal,", "fatal_fault_i => w_ecc_fatal,")]),
    ("test: comparator on the cold reset alone", TOP, [(r"rst_n_syn_i => w_comparator_rst_n", "rst_n_syn_i => w_cold_rst_n")]),
    ("test: NMI pin shows the self-test", TOP, [(r"nmi_fault_o <= \(w_nmi and w_self_test_passed\) or w_self_test_failed;", "nmi_fault_o <= w_nmi or w_self_test_failed;")]),
    ("test: NMI pin misses a failure", TOP, [(r"nmi_fault_o <= \(w_nmi and w_self_test_passed\) or w_self_test_failed;", "nmi_fault_o <= w_nmi and w_self_test_passed;")]),

    # --- CAN reception
    ("rx: stuff bit after 4", RX, [(r"c_stuff_run : unsigned\(2 downto 0\)  := to_unsigned\(5, 3\)", "c_stuff_run : unsigned(2 downto 0)  := to_unsigned(4, 3)")]),
    ("rx: stuff bit after 6", RX, [(r"c_stuff_run : unsigned\(2 downto 0\)  := to_unsigned\(5, 3\)", "c_stuff_run : unsigned(2 downto 0)  := to_unsigned(6, 3)")]),
    ("rx: six identical bits accepted", RX, [(r"v_bad  := rx_i = r_last;", "v_bad  := false;")]),
    ("rx: no stuff bit after the last CRC bit", RX, [(r" or \(r_field = field_crc_delim and r_run = c_stuff_run\)\)", ")")]),
    ("rx: stuff bit does not start a run", RX, [(r"(r_last <= rx_i;\s+)r_run  <= to_unsigned\(1, 3\);", r"\1r_run  <= to_unsigned(0, 3);")]),
    ("rx: run not counted", RX, [(r"if \(rx_i = r_last\) then\s+r_run <= r_run \+ 1;", "if (false) then r_run <= r_run + 1;")]),
    ("rx: wrong CRC polynomial", RX, [(r"16#4599#", "16#4598#")]),
    ("rx: CRC not checked", RX, [(r"w_crc_good <= '1' when \(r_crc = 0\) else", "w_crc_good <= '1' when (true) else")]),
    ("rx: CRC error not flagged", RX, [(r"v_bad   := rx_i = '0' or w_crc_good = '0';", "v_bad   := rx_i = '0';")]),
    ("rx: bad CRC acknowledged", RX, [(r"if \(r_field = field_ack and w_crc_good = '1' and transmitting_i = '0'\) then", "if (r_field = field_ack and transmitting_i = '0') then")]),
    ("rx: own frames acknowledged", RX, [(r"if \(r_field = field_ack and w_crc_good = '1' and transmitting_i = '0'\) then", "if (r_field = field_ack and w_crc_good = '1') then")]),
    ("rx: no ACK", RX, [(r"if \(r_field = field_ack and w_crc_good = '1' and transmitting_i = '0'\) then", "if (false) then")]),
    ("rx: ACK not read back", RX, [(r"v_bad   := r_pin = '0' and rx_i = '1';", "v_bad   := false;")]),
    ("rx: CRC delimiter not checked", RX, [(r"v_bad   := rx_i = '0';\s+r_field <= field_ack;", "r_field <= field_ack;")]),
    ("rx: ACK delimiter not checked", RX, [(r"v_bad   := rx_i = '0' or w_crc_good = '0';", "v_bad   := w_crc_good = '0';")]),
    ("rx: EOF not checked", RX, [(r"if \(r_count < 6\) then\s+v_bad := rx_i = '0';\s+end if;", "")]),
    ("rx: dominant last EOF bit is an error", RX, [(r"if \(r_count < 6\) then\s+v_bad", "if (r_count < 7) then v_bad")]),
    ("rx: frame delivered a bit late", RX, [(r"if \(r_count = 5 and rx_i = '1' and transmitting_i = '0'\) then", "if (r_count = 6 and rx_i = '1' and transmitting_i = '0') then")]),
    ("rx: frame delivered despite a dominant bit", RX, [(r"if \(r_count = 5 and rx_i = '1' and transmitting_i = '0'\) then", "if (r_count = 5 and transmitting_i = '0') then")]),
    ("rx: own frames delivered", RX, [(r"if \(r_count = 5 and rx_i = '1' and transmitting_i = '0'\) then", "if (r_count = 5 and rx_i = '1') then")]),
    ("rx: errors in own frames flagged", RX, [(r"if \(transmitting_i = '1'\) then\s+r_field <= field_wait;\s+else\s+r_field   <= field_flag;\s+r_bad_bit <= '1';\s+end if;", "r_field   <= field_flag; r_bad_bit <= '1';")]),
    ("rx: errors not flagged", RX, [(r"r_field   <= field_flag;\s+r_bad_bit <= '1';", "r_field   <= field_wait; r_bad_bit <= '1';")]),
    ("rx: flag 5 bits", RX, [(r"c_flag_bits : unsigned\(2 downto 0\)  := to_unsigned\(6, 3\)", "c_flag_bits : unsigned(2 downto 0)  := to_unsigned(5, 3)")]),
    ("rx: flag 7 bits", RX, [(r"c_flag_bits : unsigned\(2 downto 0\)  := to_unsigned\(6, 3\)", "c_flag_bits : unsigned(2 downto 0)  := to_unsigned(7, 3)")]),
    ("rx: passive flag dominant", RX, [(r"r_pin       <= error_passive_i;", "r_pin       <= '0';")]),
    ("rx: active flag recessive", RX, [(r"r_pin       <= error_passive_i;", "r_pin       <= '1';")]),
    ("rx: dominant after the flag not counted", RX, [(r"r_flag_stepped <= not rx_i;", "r_flag_stepped <= '0';")]),
    ("rx: any bit after the flag counted", RX, [(r"r_flag_stepped <= not rx_i;", "r_flag_stepped <= '1';")]),
    ("rx: errors not counted", RX, [(r"if \(r_rec /= c_rec_limit\) then\s+r_rec <= r_rec \+ 1;", "if (false) then null;")]),
    ("rx: error count wraps", RX, [(r"if \(r_rec /= c_rec_limit\) then", "if (true) then")]),
    ("rx: dominant after the flag wraps the count", RX, [(r"if \(r_rec > c_rec_limit - c_rec_step\) then\s+r_rec <= c_rec_limit;\s+else\s+r_rec <= r_rec \+ c_rec_step;\s+end if;", "r_rec <= r_rec + c_rec_step;")]),
    ("rx: step of 7", RX, [(r"c_rec_step  : unsigned\(7 downto 0\)  := to_unsigned\(8, 8\)", "c_rec_step  : unsigned(7 downto 0)  := to_unsigned(7, 8)")]),
    ("rx: good frames do not count down", RX, [(r"elsif \(r_rec /= 0\) then\s+r_rec <= r_rec - 1;", "elsif (false) then null;")]),
    ("rx: above 127 only counts down", RX, [(r"if \(r_rec > c_rec_good\) then\s+r_rec <= c_rec_good;\s+elsif", "if (false) then null; elsif")]),
    ("rx: extended frames not followed", RX, [(r"if \(rx_i = '1'\) then\s+r_field <= field_ext_id;", "if (false) then r_field <= field_ext_id;")]),
    ("rx: extended identifier a bit short", RX, [(r"if \(r_count = 17\) then", "if (r_count = 16) then")]),
    ("rx: r1 skipped", RX, [(r"r_rtr   <= rx_i;\s+r_field <= field_r1;", "r_rtr   <= rx_i; r_field <= field_r0;")]),
    ("rx: remote frame expects data", RX, [(r"if \(r_rtr = '1' or v_dlc = 0\) then", "if (v_dlc = 0) then")]),
    ("rx: DLC above 8 not limited", RX, [(r"if \(dlc > 8\) then\s+return to_unsigned\(64, 7\);\s+end if;", "null;")]),
    ("rx: data from the wrong end", RX, [(r"r_data\(63 - to_integer\(r_count\)\) <= rx_i;", "r_data(to_integer(r_count)) <= rx_i;")]),
    ("rx: extended flag lost", RX, [(r"ide_o         <= r_ide;", "ide_o         <= '0';")]),
    ("rx: remote flag lost", RX, [(r"rtr_o         <= r_rtr;", "rtr_o         <= '0';")]),
    ("rx: old data kept", RX, [(r"r_data  <= \(others => '0'\);\s+end if;\s+when field_id", "end if; when field_id")]),
    ("rx: out of the frame during the flag", RX, [(r"in_frame_o  <= '0' when \(r_field = field_wait\) else", "in_frame_o  <= '0' when (r_field = field_wait or r_field = field_flag) else")]),
    ("rx: a TX failure leaves the receiver in the frame", RX, [(r"if \(clear_i = '1' or tx_failed_i = '1'\) then\s+r_field      <= field_wait;", "if (clear_i = '1') then r_field      <= field_wait;")]),
    ("rx: pin not reset", RX, [(r"(if \(clear_i = '1' or tx_failed_i = '1'\) then\s+)r_pin       <= '1';", r"\1null;")]),
    ("rx: SOF after 9 recessive bits", CAN, [(r"w_sof_allowed <= '1' when \(r_recessive_run >= c_idle_bits - 1\) else", "w_sof_allowed <= '1' when (r_recessive_run >= c_idle_bits - 2) else")]),
    ("rx: SOF only on an idle bus", CAN, [(r"w_sof_allowed <= '1' when \(r_recessive_run >= c_idle_bits - 1\) else", "w_sof_allowed <= '1' when (r_recessive_run >= c_idle_bits) else")]),
    ("rx: flag not timed from its end", CAN, [(r"if \(w_flag_done = '1' or w_rx_flag_done = '1'\) then", "if (w_flag_done = '1') then")]),
    ("rx: a receive error is not passive", CAN, [(r"w_error_passive <= '1' when \(r_tec >= c_tec_passive or w_rec >= c_rec_passive\) else", "w_error_passive <= '1' when (r_tec >= c_tec_passive) else")]),
    ("rx: pin not reaching the bus", CAN, [(r"can_tx_o <= \(r_tx_pin and w_rx_pin\) when", "can_tx_o <= r_tx_pin when")]),
    ("rx: gate does not stop reception", CAN, [(r"clear_i         => w_tx_clear,", "clear_i         => not rst_n_i,")]),
    ("rx: TX failure not passed on", CAN, [(r"tx_failed_i     => w_tx_fail,", "tx_failed_i     => '0',")]),
    ("rx: always acts as a receiver", CAN, [(r"transmitting_i  => w_transmitting,", "transmitting_i  => '0',")]),
    ("sync: no resynchronisation", CAN, [(r"w_resync <= '1' when \(w_rx_fall = '1' and r_state = idle and w_rx_in_frame = '1' and w_rx_pin = '1' and\s+r_sampled = '1' and r_resynced = '0'\) else", "w_resync <= '1' when (false) else")]),
    ("sync: hard sync on every edge", CAN, [(r"w_hard_sync <= '1' when \(w_rx_fall = '1' and r_state = idle and w_rx_in_frame = '0'\) else", "w_hard_sync <= '1' when (w_rx_fall = '1' and r_state = idle) else")]),
    ("sync: no limit on a late edge", CAN, [(r"r_bit_cnt - 1 \+ minimum\(maximum\(c_edge_cnt - r_bit_cnt, 0\), c_sjw\)", "r_bit_cnt - 1 + maximum(c_edge_cnt - r_bit_cnt, 0)")]),
    ("sync: late edges ignored", CAN, [(r"elsif \(w_resync = '1' and r_bit_cnt > c_sample_cnt\) then", "elsif (false) then")]),
    ("sync: early edges ignored", CAN, [(r"elsif \(w_resync = '1'\) then\s+-- After it", "elsif (false) then -- After it")]),
    ("sync: early edge not limited", CAN, [(r"maximum\(r_bit_cnt - 1 - c_sjw, 0\)", "0")]),
    ("sync: two edges in a bit", CAN, [(r"r_sampled = '1' and r_resynced = '0'\) else", "r_sampled = '1') else")]),
    ("sync: edges after a dominant bit", CAN, [(r"r_sampled = '1' and r_resynced = '0'\) else", "r_resynced = '0') else")]),
    ("sync: follows its own edges", CAN, [(r"w_rx_in_frame = '1' and w_rx_pin = '1' and", "w_rx_in_frame = '1' and")]),
    ("sync: transmitter follows edges", CAN, [(r"w_resync <= '1' when \(w_rx_fall = '1' and r_state = idle and", "w_resync <= '1' when (w_rx_fall = '1' and")]),
    ("buf: a new frame overwrites", CAN, [(r"if \(r_buf_full = '0' or w_buf_release = '1'\) then", "if (true) then")]),
    ("buf: a frame on a release is lost", CAN, [(r"if \(r_buf_full = '0' or w_buf_release = '1'\) then", "if (r_buf_full = '0') then")]),
    ("buf: overrun not reported", CAN, [(r"r_buf_overrun <= '1';", "null;")]),
    ("buf: release leaves the overrun", CAN, [(r"r_buf_full    <= '0';\s+r_buf_overrun <= '0';\s+end if;\s+if \(w_rx_valid", "r_buf_full    <= '0'; end if; if (w_rx_valid")]),
    ("buf: release ignores the gate", CAN, [(r"w_buf_release <= '1' when \(bus_ok_i = '1' and ", "w_buf_release <= '1' when (")]),
    ("buf: release takes a partial store", CAN, [(r'(w_buf_release <= .1. when \(bus_ok_i = .1. and bus_i\.valid = .1. and bus_i\.we = .1. and )bus_i\.sel = "1111" and', r"\1")]),
    ("buf: a read releases", CAN, [(r"(w_buf_release <= '1' when \(bus_ok_i = '1' and bus_i\.valid = '1' and )bus_i\.we = '1' and ", r"\1")]),
    ("buf: release ignores the high address bits", CAN, [(r"bus_i\.addr = c_can_rx_status_addr\) else", "bus_i.addr(11 downto 0) = c_can_rx_status_addr(11 downto 0)) else")]),
    ("buf: interrupt always enabled", CAN, [(r"can_irq_o <= r_error_irq or \(r_buf_full and r_buf_irq_en\);", "can_irq_o <= r_error_irq or r_buf_full;")]),
    ("buf: frames raise no interrupt", CAN, [(r"can_irq_o <= r_error_irq or \(r_buf_full and r_buf_irq_en\);", "can_irq_o <= r_error_irq;")]),
    ("buf: enable cannot be set", CAN, [(r"r_buf_irq_en <= bus_i\.data\(0\);", "null;")]),
    ("buf: RX_ID ignores the high address bits", CAN, [(r"elsif \(bus_i\.addr = c_can_rx_id_addr\) then", "elsif (bus_i.addr(11 downto 0) = c_can_rx_id_addr(11 downto 0)) then")]),
    ("buf: RX_INFO ignores the high address bits", CAN, [(r"elsif \(bus_i\.addr = c_can_rx_info_addr\) then", "elsif (bus_i.addr(11 downto 0) = c_can_rx_info_addr(11 downto 0)) then")]),
    ("buf: RX_DATA ignores the high address bits", CAN, [(r"elsif \(bus_i\.addr = c_can_rx_data_addr\) then", "elsif (bus_i.addr(11 downto 0) = c_can_rx_data_addr(11 downto 0)) then")]),
    ("buf: RX_DATA_HI ignores the high address bits", CAN, [(r"elsif \(bus_i\.addr = c_can_rx_data_hi_addr\) then", "elsif (bus_i.addr(11 downto 0) = c_can_rx_data_hi_addr(11 downto 0)) then")]),
    ("buf: RX_STATUS ignores the high address bits", CAN, [(r"elsif \(bus_i\.addr = c_can_rx_status_addr\) then", "elsif (bus_i.addr(11 downto 0) = c_can_rx_status_addr(11 downto 0)) then")]),
    ("buf: REC not shown", CAN, [(r"r_rdata\(31 downto 24\) <= std_logic_vector\(w_rec\);", "null;")]),
    ("top: frame does not reach the program", PKG, [(r'c_can_rx_id_addr      : std_logic_vector\(c_addr_width - 1 downto 0\) := x"40000318"', 'c_can_rx_id_addr      : std_logic_vector(c_addr_width - 1 downto 0) := x"40000338"')]),

    ("can: wrong CRC polynomial", CAN, [(r"16#4599#", "16#4598#")]),
    ("can: CRC skips header", CAN,
     [(r"if \(w_crc_field = '1' and \(w_next_bit", "if (r_state = tx_data and (w_next_bit")]),
    ("can: CRC sent LSB end", CAN, [(r"r_crc_reg\(14\) when \(r_state = tx_crc\)", "r_crc_reg(0) when (r_state = tx_crc)")]),

    # --- Bit stuffing
    ("can: stuff after 4 bits", CAN, constant("c_stuff_run", 5, 4)),
    ("can: stuff after 6 bits", CAN, constant("c_stuff_run", 5, 6)),
    ("can: stuff bit not complementary", CAN, [(r"r_tx_pin      <= not r_tx_pin;", "r_tx_pin      <= r_tx_pin;")]),
    ("can: stuff bit does not start a run", CAN,
     [(r"(r_tx_pin      <= not r_tx_pin;\s+)r_stuff_count <= to_unsigned\(1, 3\);", r"\1r_stuff_count <= (others => '0');")]),
    ("can: stuff bit overwrites a frame bit", CAN,
     [(r"w_send_bit <= w_bit_tick and not \(w_stuff_insert or ", "w_send_bit <= w_bit_tick and not (")]),
    ("can: no stuff bit after the last CRC bit", CAN,
     [(r"w_stuff_insert <= '1' when \(r_stuff_count = c_stuff_run\) else",
       "w_stuff_insert <= '1' when (r_stuff_count = c_stuff_run and w_stuffed_field = '1') else")]),
    ("can: CRC sequence not stuffed", CAN,
     [(r"w_stuffed_field <= '1' when \(w_crc_field = '1' or r_state = tx_crc\) else",
       "w_stuffed_field <= '1' when (w_crc_field = '1') else")]),
    ("can: tail bits stuffed", CAN,
     [(r"if \(w_stuffed_field = '0'\) then\s+r_stuff_count <= \(others => '0'\);\s+elsif \(w_next_bit = r_tx_pin\) then",
       "if (w_next_bit = r_tx_pin) then")]),

    # --- Serialiser and frame format
    ("can: shift register stuck", CAN, [(r"r_tx_shift     <= r_tx_shift\(62 downto 0\) & '0';", "r_tx_shift     <= r_tx_shift;")]),
    ("can: RTR recessive", CAN, [(r"c_dominant : std_logic_vector\(0 downto 0\) := \"0\"",
                                  "c_dominant : std_logic_vector(0 downto 0) := \"1\"")]),
    ("can: IDE recessive", CAN, [(r"c_ctrl_hdr : std_logic_vector\(1 downto 0\) := \"00\"",
                                  "c_ctrl_hdr : std_logic_vector(1 downto 0) := \"10\"")]),
    ("can: r0 recessive", CAN, [(r"c_ctrl_hdr : std_logic_vector\(1 downto 0\) := \"00\"",
                                 "c_ctrl_hdr : std_logic_vector(1 downto 0) := \"01\"")]),
    ("can: data sent from the wrong end", CAN, [(r"r_tx_shift     <= r_mailbox_data;", "r_tx_shift     <= r_mailbox_data(31 downto 0) & r_mailbox_data(63 downto 32);")]),
    ("can: DLC above 8 not limited", CAN, [(r"if \(dlc > 8\) then", "if (dlc > 14) then")]),
    ("can: ACK field too short", CAN, constant("c_ack_bits", 3, 2)),
    ("can: EOF one bit short", CAN, constant("c_eof_bits", 8, 7)),
    ("can: EOF one bit long", CAN, constant("c_eof_bits", 8, 9)),
    ("can: bit one clock short", CAN, [(r"r_bit_cnt <= g_clks_per_bit - 1;", "r_bit_cnt <= g_clks_per_bit - 2;")]),

    # --- Mailbox
    ("can: mailbox never released", CAN,
     [(r"elsif \(w_frame_done = '1'\) then\s+r_mailbox_full <= '0';\s+elsif", "elsif")]),

    # --- Safety gate
    ("can: TX pin not gated", CAN, [(r"can_tx_o <= \(r_tx_pin and w_rx_pin\) when \(bus_ok_i = '1' and rst_n_i = '1'\) else\s+'1';", "can_tx_o <= r_tx_pin and w_rx_pin;")]),
    ("can: TX pin not forced recessive in reset", CAN, [(r"can_tx_o <= \(r_tx_pin and w_rx_pin\) when \(bus_ok_i = '1' and rst_n_i = '1'\) else", "can_tx_o <= (r_tx_pin and w_rx_pin) when (bus_ok_i = '1') else")]),
    ("can: gate drop does not abandon the frame", CAN,
     [(CLEAR, "w_tx_clear <= '1' when (rst_n_i = '0' or r_bus_off = '1') else")]),
    ("can: TX pin survives a gate drop", CAN,
     [(r"if \(w_tx_clear = '1'\) then(\s+)r_stuff_count", r"if (rst_n_i = '0') then\1r_stuff_count")]),
    ("can: mailbox ignores the gate", CAN,
     [(CLEAR, "w_tx_clear <= '1' when (rst_n_i = '0' or r_bus_off = '1') else"),
      (r"w_mailbox_write <= '1' when \(bus_ok_i = '1' and bus_i.valid", "w_mailbox_write <= '1' when (bus_i.valid")]),
    ("can: gate drop clears the error counter", CAN,
     [(r"if \(rst_n_i = '0'\) then(\s+)r_tec ", r"if (w_tx_clear = '1') then\1r_tec ")]),

    # --- Bus idle and start of frame
    ("can: idle after 10 recessive bits", CAN, natural("c_idle_bits", 11, 10)),
    ("can: idle after 12 recessive bits", CAN, natural("c_idle_bits", 11, 12)),
    ("can: starts without an idle bus", CAN,
     [(r"\(r_bus_idle = '1' and \(w_bit_tick = '1' or w_rx_fall = '1'\)\)", "(w_bit_tick = '1' or w_rx_fall = '1')")]),
    ("can: no re-phasing on bus edges", CAN, [(r"w_hard_sync <= '1' when \(w_rx_fall = '1' and r_state = idle and w_rx_in_frame = '0'\) else", "w_hard_sync <= '1' when (false) else")]),
    ("can: does not join a SOF edge", CAN, [(r"\(w_bit_tick = '1' or w_rx_fall = '1'\)\)\)\) else", "w_bit_tick = '1'))) else")]),
    ("can: does not join a SOF in intermission", CAN, [(r"\(w_ifs_sof = '1' or \(r_bus_idle", "(false or (r_bus_idle")]),
    ("can: sample point at the start of the bit", CAN,
     natural("c_sample_cnt", r"g_clks_per_bit - \(3 \* g_clks_per_bit\) / 4", "g_clks_per_bit - 1")),

    # --- Arbitration
    ("can: lost arbitration ignored", CAN, [(r"r_arb_lost <= '1';", "null;")]),
    ("can: lost arbitration is a bit error", CAN, [(r"r_arb_lost <= '1';", "r_bit_error <= '1';")]),
    ("can: arbitration covers the control field", CAN,
     [(r"if \(r_state = tx_id\) then(\s+)r_cur_arb <= '1';", r"if (r_state = tx_id or r_state = tx_ctrl) then\1r_cur_arb <= '1';")]),
    ("can: arbitration stops before the last ID bit", CAN,
     [(r"if \(r_state = tx_id\) then(\s+)r_cur_arb <= '1';", r"if (r_state = tx_id and r_tx_bits_left > 2) then\1r_cur_arb <= '1';")]),
    ("can: stuff bit loses arbitration", CAN, [(r"elsif \(r_cur_stuff = '0'\) then", "elsif (true) then")]),

    # --- ACK and bit errors
    ("can: missing ACK ignored", CAN, [(r"w_ack_missing <= '1' when \(w_frame_active", "w_ack_missing <= '1' when (false and w_frame_active")]),
    ("can: ACK checked in the wrong bit", CAN,
     [(r"r_state = tx_ack and r_tx_bits_left = 2 and w_stuff_insert", "r_state = tx_ack and r_tx_bits_left = 3 and w_stuff_insert")]),
    ("can: ACK treated as a bit error", CAN, [(r"elsif \(r_cur_ack = '1'\) then(\s+)r_ack_seen <= '1';", r"elsif (r_cur_ack = '1') then\1r_bit_error <= '1';")]),
    ("can: recessive read on dominant ignored", CAN,
     [(r"if \(r_tx_pin = '0'\) then(\s+)r_bit_error <= '1';", r"if (r_tx_pin = '0') then\1null;")]),
    ("can: dominant read on recessive ignored", CAN,
     [(r"elsif \(r_cur_arb = '0'\) then(\s+)r_bit_error <= '1';", r"elsif (r_cur_arb = '0') then\1null;")]),
    ("can: EOF not monitored", CAN,
     [(r"w_frame_active <= '1' when \(r_state /= idle and r_state /= tx_error_flag\) else",
       "w_frame_active <= '1' when (r_state /= idle and r_state /= tx_error_flag and r_state /= tx_eof) else")]),

    # --- Retransmission
    ("can: failed frame dropped", CAN, [(r"elsif \(w_frame_done = '1'\) then(\s+)r_mailbox_full", r"elsif (w_frame_done = '1' or w_flag_done = '1') then\1r_mailbox_full")]),
    ("can: frame dropped on lost arbitration", CAN, [(r"elsif \(w_frame_done = '1'\) then(\s+)r_mailbox_full", r"elsif (w_frame_done = '1' or w_arb_fail = '1') then\1r_mailbox_full")]),

    # --- Error flag
    ("can: error flag 5 bits", CAN, constant("c_flag_bits", 6, 5)),
    ("can: error flag 7 bits", CAN, constant("c_flag_bits", 6, 7)),
    ("can: passive flag dominant", CAN, [(r"w_flag_level <= '1' when \(w_error_passive = '1'\) else", "w_flag_level <= '1' when (false) else")]),
    ("can: active flag recessive", CAN, [(r"w_flag_level <= '1' when \(w_error_passive = '1'\) else", "w_flag_level <= '1' when (true) else")]),
    ("can: error delimiter not counted from the flag", CAN, [(r"if \(w_flag_done = '1' or w_rx_flag_done = '1'\) then\s+r_recessive_run <= 0;", "if (w_rx_flag_done = '1') then r_recessive_run <= 0;")]),
    ("sync: a sample on the clock of a hard sync", CAN, [(r"w_sample_tick <= '1' when \(r_bit_cnt = c_sample_cnt and w_hard_sync = '0'\) else", "w_sample_tick <= '1' when (r_bit_cnt = c_sample_cnt) else")]),

    # --- Fault confinement
    ("can: error adds 7", CAN, constant("c_tec_step", 8, 7)),
    ("can: good frame does not take away 1", CAN, [(r"r_tec <= r_tec - 1;", "null;")]),
    ("can: error passive at 127", CAN, constant("c_tec_passive", 128, 127)),
    ("can: error passive at 129", CAN, constant("c_tec_passive", 128, 129)),
    ("can: bus-off at 248", CAN, constant("c_tec_bus_off", 256, 248)),
    ("can: bus-off at 264", CAN, [(r"c_tec_bus_off : unsigned\(8 downto 0\) := to_unsigned\(256, 9\)",
                                   "c_tec_bus_off : unsigned(8 downto 0) := to_unsigned(511, 9)")]),
    ("can: bus-off does not stop the node", CAN, [(CLEAR, "w_tx_clear <= '1' when (rst_n_i = '0' or bus_ok_i = '0') else")]),
    ("can: lone node ACK exception removed", CAN,
     [(r"w_count_error <= not \(r_uncounted or \(r_ack_error and w_error_passive and not r_flag_dominant\)\);",
       "w_count_error <= not r_uncounted;")]),
    ("can: answered passive flag not counted", CAN,
     [(r"w_count_error <= not \(r_uncounted or \(r_ack_error and w_error_passive and not r_flag_dominant\)\);",
       "w_count_error <= not (r_uncounted or (r_ack_error and w_error_passive));")]),
    ("can: stuff bit exception removed", CAN,
     [(r"w_count_error <= not \(r_uncounted or \(r_ack_error", "w_count_error <= not ((r_ack_error")]),
    ("can: no suspend time", CAN, natural("c_suspend_bits", 8, 0)),
    ("can: no suspend after a good frame", CAN,
     [(r"if \(\(w_frame_done = '1' or w_flag_done = '1'\) and w_error_passive = '1'\) then",
       "if (w_flag_done = '1' and w_error_passive = '1') then")]),
    ("can: suspend time does not give way", CAN,
     [(r"if \(r_recessive_run >= c_idle_bits\) then\s+r_suspend <= '0';\s+end if;", "")]),
]


# Benches that run firmware on the cores. Every other bench is quick, so a
# mutant meets those first, and the full regression only if it gets past them.
SLOW_BENCHES = {
    "tb_soc_addr_boundary", "tb_soc_ecc", "tb_soc_firmware", "tb_soc_lockstep",
    "tb_soc_reset_network", "tb_soc_uart_error", "tb_soc_watchdog",
}

# run.py does not use sim/OsvvmLibraries, which is most of the tree
COPY_IGNORE = shutil.ignore_patterns(".git", "vunit_out", "__pycache__", "*.cf", "OsvvmLibraries")

LABELS = {
    "killed": "killed ",
    "survive": "SURVIVE",
    "nofail": "NOFAIL ",
    "timeout": "TIMEOUT",
    "compile": "COMPILE",
    "skip": "SKIP   ",
}


def parse_args():
    env = os.environ.get
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("names", nargs="*", metavar="NAME",
                        help="run only the mutants whose name contains one of these")
    parser.add_argument("--check", action="store_true",
                        help="check that every mutant still applies to the RTL, and run nothing")
    parser.add_argument("--list", action="store_true", help="print the mutant names and stop")
    parser.add_argument("--shard", metavar="K/N", help="take every Nth mutant, starting from the Kth")
    parser.add_argument("--names-file", metavar="FILE", default=env("MUTATE_LIST"),
                        help="run exactly the mutants named in FILE, one per line")
    parser.add_argument("--repo", metavar="DIR", type=Path, default=Path(env("MUTATE_REPO") or ROOT),
                        help="the tree to copy and mutate (default: this checkout)")
    parser.add_argument("-p", "--jobs", type=int, default=int(env("MUTATE_P") or os.cpu_count() or 4),
                        help="simulations run.py runs at once (default: one per CPU)")
    parser.add_argument("--fast", metavar="PATTERNS", default=env("MUTATE_FAST"),
                        help="space-separated test patterns to run before the full regression, '' for "
                             "none (default: every bench but the firmware ones)")
    parser.add_argument("--timeout", type=float, default=1800, metavar="SECONDS",
                        help="the longest one run.py call may take (default: 1800)")
    parser.add_argument("--no-baseline", action="store_true", default=bool(env("MUTATE_NO_BASELINE")),
                        help="skip the unmutated run, when it is known to pass")
    return parser.parse_args()


def select(args):
    chosen = MUTANTS
    if args.names:
        chosen = [m for m in chosen if any(part in m[0] for part in args.names)]
    if args.names_file:
        lines = Path(args.names_file).read_text(encoding="utf-8").splitlines()
        wanted = {line.strip() for line in lines} - {""}
        unknown = wanted - {name for name, _, _ in MUTANTS}
        if unknown:
            sys.exit(f"{args.names_file} names mutants that do not exist: {sorted(unknown)}")
        chosen = [m for m in chosen if m[0] in wanted]
    if args.shard:
        match = re.fullmatch(r"([0-9]+)/([0-9]+)", args.shard)
        if not match or not 1 <= int(match[1]) <= int(match[2]):
            sys.exit(f"--shard wants K/N with 1 <= K <= N, not {args.shard}")
        chosen = chosen[int(match[1]) - 1::int(match[2])]
    return chosen


def prepare(path, subs):
    """Return the file as it is, and as the mutant has it, or why that cannot be made."""
    if not path.is_file():
        return None, None, f"{path} does not exist"
    original = path.read_bytes()
    text = original.decode("utf-8").replace("\r\n", "\n")
    mutated = text
    for pattern, replacement in subs:
        mutated, count = re.subn(pattern, replacement, mutated, count=1, flags=re.S)
        if count != 1:
            return original, None, f"pattern did not match: {pattern[:70]}"
    if mutated == text:
        return original, None, "the substitutions change nothing"
    return original, mutated, None


def check(repo, chosen):
    problems = 0
    for name, count in Counter(m[0] for m in MUTANTS).items():
        if count > 1:
            problems += 1
            print(f"name used {count} times: {name}")
    for name, rel, subs in chosen:
        _, _, problem = prepare(repo / rel, subs)
        if problem:
            problems += 1
            print(f"[{LABELS['skip']}] {name}: {problem}")
    print(f"{len(chosen)} mutant(s), {problems} problem(s)")
    return 1 if problems else 0


def kill_tree(proc):
    """Stop run.py and every simulator it started."""
    if os.name == "nt":
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)], capture_output=True, check=False)
    else:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def regression(repo, patterns, args):
    """Run run.py in the copy. Returns its exit code, or None on a timeout, and its output."""
    env = dict(os.environ, LOCKSTEP_NO_LINT="1", PYTHONIOENCODING="utf-8", PYTHONUNBUFFERED="1")
    cmd = [sys.executable, "run.py", "--no-color", "-p", str(args.jobs), *patterns]
    # In a group of its own, so that a timeout can stop the simulators too
    group = ({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt"
             else {"start_new_session": True})
    with subprocess.Popen(cmd, cwd=repo / "sim", env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          encoding="utf-8", errors="replace", **group) as proc:
        try:
            out, _ = proc.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            kill_tree(proc)
            return None, proc.communicate()[0]
        except BaseException:
            kill_tree(proc)
            raise
    return proc.returncode, out


def classify(rc, out):
    if rc is None:
        return "timeout", ""
    if "Compile failed" in out:
        error = next((line.strip() for line in out.splitlines() if "error" in line.lower()), "")
        return "compile", error[-130:]
    if rc == 0:
        return "survive", ""
    failed = sorted(set(re.findall(r"^fail\s+sim_lib\.(\w+)\.(\S+)", out, re.M)))
    if failed:
        benches = sorted({bench for bench, _ in failed})
        return "killed", f"{len(failed)} test(s) in {', '.join(benches)}"
    last = next((line.strip() for line in reversed(out.splitlines()) if line.strip()), "")
    return "nofail", f"exit {rc} with no failing test, last line: {last[-100:]}"


def attempt(repo, fast, args):
    """The quick benches first, then the full regression if they all pass."""
    rc, out = regression(repo, fast, args)
    if rc == 0 and fast:
        rc, out = regression(repo, [], args)
    return classify(rc, out)


def clean_build(repo):
    shutil.rmtree(repo / "sim" / "vunit_out", ignore_errors=True)
    for library in (repo / "sim").glob("*.cf"):
        library.unlink()


def run_mutant(repo, rel, subs, fast, args):
    path = repo / rel
    original, mutated, problem = prepare(path, subs)
    if problem:
        return "skip", problem
    path.write_bytes(mutated.encode("utf-8"))
    try:
        kind, detail = attempt(repo, fast, args)
        if kind in ("compile", "nofail"):
            # An incremental build can trip over a file swapped back and forth,
            # so build from clean before believing it
            clean_build(repo)
            kind, detail = attempt(repo, fast, args)
    finally:
        path.write_bytes(original)
    return kind, detail


def fast_patterns(repo):
    benches = sorted(path.stem for path in (repo / "sim" / "testbenches").glob("tb_*.vhd"))
    return [f"sim_lib.{bench}.*" for bench in benches if bench not in SLOW_BENCHES]


def baseline(repo, args):
    """The unmutated copy has to pass, or no result below means anything."""
    began = time.monotonic()
    rc, out = regression(repo, [], args)
    tally = re.findall(r"^pass [0-9]+ of [0-9]+", out, re.M)
    print(f"baseline: {tally[-1] if tally else 'no summary'}, exit {rc} ({time.monotonic() - began:.0f} s)",
          flush=True)
    if rc == 0:
        return True
    print("\n".join(out.splitlines()[-40:]))
    print("\nThe unmutated tree has to pass first.")
    return False


def main():
    args = parse_args()
    chosen = select(args)
    source = args.repo.resolve()
    if args.list:
        for name, _, _ in chosen:
            print(name)
        return 0
    if args.check:
        return check(source, chosen)
    if not chosen:
        sys.exit("no mutant matches that selection")

    started = time.monotonic()
    results, missed = Counter(), []
    with tempfile.TemporaryDirectory(prefix="lockstep_mutate_", ignore_cleanup_errors=True) as tmp:
        repo = Path(tmp)
        for part in ("config", "rtl", "sim"):
            shutil.copytree(source / part, repo / part, ignore=COPY_IGNORE)
        fast = args.fast.split() if args.fast is not None else fast_patterns(repo)
        print(f"{len(chosen)} of {len(MUTANTS)} mutant(s), on a copy of {source} in {repo}", flush=True)
        if not args.no_baseline and not baseline(repo, args):
            return 2
        for number, (name, rel, subs) in enumerate(chosen, 1):
            began = time.monotonic()
            kind, detail = run_mutant(repo, rel, subs, fast, args)
            results[kind] += 1
            if kind != "killed":
                missed.append(f"{kind}: {name}")
            line = f"[{LABELS[kind]}] {name}" + (f": {detail}" if detail else "")
            print(f"{line} ({time.monotonic() - began:.0f} s, {number} of {len(chosen)})", flush=True)

    counts = ", ".join(f"{results[kind]} {kind}" for kind in LABELS if results[kind])
    print(f"\n{len(chosen)} mutant(s) in {(time.monotonic() - started) / 60:.0f} min: {counts}")
    for entry in missed:
        print(f"  {entry}")
    return 1 if missed else 0


if __name__ == "__main__":
    sys.exit(main())
