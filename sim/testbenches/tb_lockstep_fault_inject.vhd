-- ============================================================================
-- Testbench: Lockstep Comparator — Fault Injection
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lockstep;
use lockstep.package_soc_types.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_lockstep_fault_inject is
    generic (runner_cfg : string := "");
end entity;

architecture rtl of tb_lockstep_fault_inject is
    constant CLK_PERIOD : time := 20 ns;
    signal tb_clk       : std_logic := '0';
    signal tb_rst_n     : std_logic := '0';
    signal core_a_bus   : t_rv_bus := (addr => (others => '0'),
                                       data => (others => '0'),
                                       we   => '0',
                                       valid => '0');
    signal core_b_bus   : t_rv_bus := (addr => (others => '0'),
                                       data => (others => '0'),
                                       we   => '0',
                                       valid => '0');
    signal nmi_fault    : std_logic;
    signal safe_state   : std_logic;
    signal bus_valid    : std_logic;
    signal sys_bus      : t_rv_bus;
begin
    tb_clk <= not tb_clk after CLK_PERIOD / 2;

    i_dut : entity lockstep.lockstep_comparator
        port map (clk_i        => tb_clk,
                  rst_n_syn_i  => tb_rst_n,
                  core_a_bus_i => core_a_bus,
                  core_b_bus_i => core_b_bus,
                  nmi_fault_o  => nmi_fault,
                  safe_state_o => safe_state,
                  bus_valid_o  => bus_valid,
                  sys_bus_o    => sys_bus);

    p_stim : process
    begin
        test_runner_setup(runner, runner_cfg);
        tb_rst_n <= '0';
        for _ in 1 to 10 loop wait until rising_edge(tb_clk); end loop;
        tb_rst_n <= '1';
        for _ in 1 to 10 loop wait until rising_edge(tb_clk); end loop;

        -- --- Fault 1: Address mismatch ---
        core_a_bus <= (addr  => x"00001000", data => x"00000001",
                       we    => '1', valid => '1');
        core_b_bus <= (addr  => x"00002000", data => x"00000001",
                       we    => '1', valid => '1');
        for _ in 1 to 3 loop wait until rising_edge(tb_clk); end loop;
        check(nmi_fault = '1', "NMI on addr mismatch");
        check(bus_valid = '0', "bus isolated on addr mismatch");

        -- --- Fault 2: Write-enable mismatch ---
        core_a_bus <= (addr  => x"00003000", data => x"00000002",
                       we    => '1', valid => '1');
        core_b_bus <= (addr  => x"00003000", data => x"00000002",
                       we    => '0', valid => '1');
        for _ in 1 to 3 loop wait until rising_edge(tb_clk); end loop;
        check(nmi_fault = '1', "NMI on WE mismatch (latched)");

        -- --- Fault 3: Single-bit data flip ---
        core_a_bus <= (addr  => x"00004000", data => x"00000000",
                       we    => '1', valid => '1');
        core_b_bus <= (addr  => x"00004000", data => x"00000001",
                       we    => '1', valid => '1');
        for _ in 1 to 3 loop wait until rising_edge(tb_clk); end loop;
        check(nmi_fault = '1', "NMI on single-bit data flip (latched)");

        test_runner_cleanup(runner);
    end process;
end architecture rtl;