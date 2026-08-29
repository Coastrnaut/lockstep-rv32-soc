-- ============================================================================
-- Testbench: Lockstep Comparator — Mismatch Injection
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lockstep;
use lockstep.package_soc_types.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_lockstep_comparator is
  generic (runner_cfg : string := "");
end entity;

architecture rtl of tb_lockstep_comparator is
    constant CLK_PERIOD : time := 20 ns;
    signal tb_clk       : std_logic := '0';
    signal tb_rst_n     : std_logic := '0';
    signal core_a_bus   : t_rv_bus;
    signal core_b_bus   : t_rv_bus;
    signal nmi_fault    : std_logic;
    signal safe_state   : std_logic;
    signal bus_valid    : std_logic;
    signal sys_bus      : t_rv_bus;
begin
    tb_clk <= not tb_clk after CLK_PERIOD / 2;

    i_dut : entity lockstep.lockstep_comparator
        port map (clk_i => tb_clk, rst_n_syn_i => tb_rst_n,
                  core_a_bus_i => core_a_bus, core_b_bus_i => core_b_bus,
                  nmi_fault_o => nmi_fault, safe_state_o => safe_state,
                  bus_valid_o => bus_valid, sys_bus_o => sys_bus);

    p_stim : process
    begin
        test_runner_setup(runner, runner_cfg);
        core_a_bus <= (addr => (others => '0'), data => (others => '0'), we => '0', valid => '0');
        core_b_bus <= (addr => (others => '0'), data => (others => '0'), we => '0', valid => '0');

        tb_rst_n <= '0';
        for dummy in 1 to 5 loop wait until rising_edge(tb_clk); end loop;
        tb_rst_n <= '1';
        for dummy in 1 to 5 loop wait until rising_edge(tb_clk); end loop;

        -- Normal: identical cores
        for i in 0 to 4 loop
            core_a_bus <= (addr => std_logic_vector(to_unsigned(i,32)),
                           data => std_logic_vector(to_unsigned(i*4,32)),
                           we => '1', valid => '1');
            core_b_bus <= core_a_bus;
            wait until rising_edge(tb_clk);
        end loop;
        wait for 0 ns;
        check(bus_valid = '1', "bus_valid high during normal op");
        check(nmi_fault = '0', "no NMI during normal op");

        -- Inject mismatch
        core_a_bus <= (addr => x"00000010", data => x"DEADBEEF", we => '1', valid => '1');
        core_b_bus <= (addr => x"00000010", data => x"CAFEBABE", we => '1', valid => '1');
        wait until rising_edge(tb_clk);
        wait until rising_edge(tb_clk);
        wait for 0 ns;
        check(nmi_fault  = '1', "NMI tripped on mismatch");
        check(safe_state = '1', "safe_state asserted");
        check(bus_valid  = '0', "bus_valid dropped");

        -- Latch stays
        core_a_bus <= (addr => (others => '0'), data => (others => '0'), we => '0', valid => '0');
        core_b_bus <= core_a_bus;
        wait until rising_edge(tb_clk);
        check(nmi_fault = '1', "NMI latched");

        test_runner_cleanup(runner);
    end process;
end architecture rtl;
