
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library vunit_lib;
context vunit_lib.vunit_context;
library lockstep;
use lockstep.package_soc_types.all;

entity tb_lockstep_fault_inject_permanent is
    generic ( runner_cfg : string := "" );
end entity;

architecture tb of tb_lockstep_fault_inject_permanent is
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
        test_runner_setup(runner, runner_cfg);

        rst_n <= '0';
        wait for 100 ns;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- TEST 1: Stuck-at-0 on data bit 0 (core B only)
        report "TEST: Stuck-at-0 data(0)";
        core_a_bus <= (addr => x"00001000", data => x"00000001", we => '1', valid => '1');
        core_b_bus <= (addr => x"00001000", data => x"00000000", we => '1', valid => '1');
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check(safe_state = '1', "stuck-at-0 bit0: fault tripped");
        check(nmi_fault = '1', "stuck-at-0 bit0: NMI");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 2: Stuck-at-1 on data bit 31 (core B only)
        -- Fault is latched, stays tripped
        report "TEST: Stuck-at-1 data(31)";
        core_a_bus <= (addr => x"00002000", data => x"00000000", we => '1', valid => '1');
        core_b_bus <= (addr => x"00002000", data => x"80000000", we => '1', valid => '1');
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check(safe_state = '1', "stuck-at-1 bit31: fault latched");
        check(nmi_fault = '1', "stuck-at-1 bit31: NMI");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 3: Stuck-at-0 on address bit 0
        report "TEST: Stuck-at-0 addr(0)";
        core_a_bus <= (addr => x"00003001", data => x"AAAAAAAA", we => '1', valid => '1');
        core_b_bus <= (addr => x"00003000", data => x"AAAAAAAA", we => '1', valid => '1');
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check(safe_state = '1', "stuck-at-0 addr(0): fault latched");
        check(nmi_fault = '1', "stuck-at-0 addr(0): NMI");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 4: Stuck-at-0 on write enable
        report "TEST: Stuck-at-0 we";
        core_a_bus <= (addr => x"00004000", data => x"11111111", we => '1', valid => '1');
        core_b_bus <= (addr => x"00004000", data => x"11111111", we => '0', valid => '1');
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check(safe_state = '1', "stuck-at-0 we: fault latched");
        check(nmi_fault = '1', "stuck-at-0 we: NMI");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 5: Permanent fault campaign (bits 0-7)
        report "TEST: Fault campaign data bits 0-7";
        for dummy in 0 to 7 loop
            core_a_bus <= (addr => x"00005000",
                           data => std_logic_vector(to_unsigned(2**dummy, 32)),
                           we => '1', valid => '1');
            core_b_bus <= (addr => x"00005000",
                           data => x"00000000",
                           we => '1', valid => '1');
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            check(safe_state = '1', "campaign bit" & integer'image(dummy) & ": fault latched");
            check(nmi_fault = '1', "campaign bit" & integer'image(dummy) & ": NMI");
            core_a_bus.valid <= '0';
            core_b_bus.valid <= '0';
            wait for CLK_PERIOD;
        end loop;

        -- TEST 6: Verify recovery after reset
        report "TEST: Recovery after reset";
        core_a_bus <= (addr => x"00006000", data => x"00000042", we => '1', valid => '1');
        core_b_bus <= (addr => x"00006000", data => x"00000042", we => '1', valid => '1');
        wait until rising_edge(clk);
        rst_n <= '0';
        wait for 20 ns;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        check(safe_state = '0', "recovery: fault cleared");
        check(nmi_fault = '0', "recovery: no NMI");
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        test_runner_cleanup(runner);
    end process;

end architecture tb;
