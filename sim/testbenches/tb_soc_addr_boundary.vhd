-- ============================================================================
-- Design Name:  Address & Data Boundary Coverage Testbench
-- Description:  Transaction sequences at min/max address and page boundaries.
-- Traces to:    VERIFICATION_SPECIFICATION.md 3A
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library lockstep;
use lockstep.package_soc_types.all;

entity tb_soc_addr_boundary is
    generic ( runner_cfg : string );
end entity;

architecture tb of tb_soc_addr_boundary is
    constant CLK_PERIOD : time := 20 ns;
    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';

    signal core_a_bus : t_rv_bus;
    signal core_b_bus : t_rv_bus;
    signal nmi_fault  : std_logic;
    signal safe_state : std_logic;
    signal bus_valid  : std_logic;
    signal sys_bus    : t_rv_bus;
begin

    clk <= not clk after CLK_PERIOD / 2;

    uut : entity lockstep.lockstep_comparator
        port map (
            clk_i        => clk,
            rst_n_syn_i  => rst_n,
            core_a_bus_i => core_a_bus,
            core_b_bus_i => core_b_bus,
            nmi_fault_o  => nmi_fault,
            safe_state_o => safe_state,
            bus_valid_o  => bus_valid,
            sys_bus_o    => sys_bus
        );

    p_test : process
    begin
        test_runner_setup(runner, "Address/Data Boundary Coverage");

        rst_n <= '0';
        wait for 100 ns;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- TEST 1: Zero address boundary
        report "TEST: Address 0x00000000";
        core_a_bus <= (addr => x"00000000", data => x"00000001", we => '1', valid => '1');
        core_b_bus <= (addr => x"00000000", data => x"00000001", we => '1', valid => '1');
        wait until rising_edge(clk);
        check(safe_state = '1', "addr 0: safe");
        check(nmi_fault = '0', "addr 0: no NMI");
        check(bus_valid = '1', "addr 0: valid");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 2: Max address boundary
        report "TEST: Address 0xFFFFFFFF";
        core_a_bus <= (addr => x"FFFFFFFF", data => x"DEADBEEF", we => '1', valid => '1');
        core_b_bus <= (addr => x"FFFFFFFF", data => x"DEADBEEF", we => '1', valid => '1');
        wait until rising_edge(clk);
        check(safe_state = '1', "addr max: safe");
        check(nmi_fault = '0', "addr max: no NMI");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 3: Page boundary 0x1000
        report "TEST: Page boundary 0x1000";
        core_a_bus <= (addr => x"00001000", data => x"12345678", we => '1', valid => '1');
        core_b_bus <= (addr => x"00001000", data => x"12345678", we => '1', valid => '1');
        wait until rising_edge(clk);
        check(safe_state = '1', "page boundary: safe");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 4: All-ones data boundary
        report "TEST: All-ones data 0xFFFFFFFF";
        core_a_bus <= (addr => x"00002000", data => x"FFFFFFFF", we => '1', valid => '1');
        core_b_bus <= (addr => x"00002000", data => x"FFFFFFFF", we => '1', valid => '1');
        wait until rising_edge(clk);
        check(safe_state = '1', "all-ones data: safe");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 5: All-zeros data boundary
        report "TEST: All-zeros data 0x00000000";
        core_a_bus <= (addr => x"00003000", data => x"00000000", we => '1', valid => '1');
        core_b_bus <= (addr => x"00003000", data => x"00000000", we => '1', valid => '1');
        wait until rising_edge(clk);
        check(safe_state = '1', "all-zeros data: safe");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 6: Address/data mismatch at boundary
        report "TEST: Data mismatch at page boundary";
        core_a_bus <= (addr => x"00001000", data => x"AAAAAAAA", we => '1', valid => '1');
        core_b_bus <= (addr => x"00001000", data => x"BBBBBBBB", we => '1', valid => '1');
        wait until rising_edge(clk);
        check(safe_state = '0', "mismatch: unsafe");
        check(nmi_fault = '1', "mismatch: NMI raised");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 7: Address mismatch
        report "TEST: Address mismatch";
        core_a_bus <= (addr => x"00004000", data => x"11111111", we => '1', valid => '1');
        core_b_bus <= (addr => x"00005000", data => x"11111111", we => '1', valid => '1');
        wait until rising_edge(clk);
        check(safe_state = '0', "addr mismatch: unsafe");
        check(nmi_fault = '1', "addr mismatch: NMI");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        test_runner_cleanup(runner);
        wait;
    end process;

end architecture tb;
