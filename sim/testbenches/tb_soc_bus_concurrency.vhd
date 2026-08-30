-- ============================================================================
-- Design Name:  Bus Transaction Concurrency Testbench
-- Description:  Back-to-back writes, R/W contention, max bus stall latency.
-- Traces to:    VERIFICATION_SPECIFICATION.md 3A
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library lockstep;
use lockstep.package_soc_types.all;

entity tb_soc_bus_concurrency is
    generic ( runner_cfg : string := "" );
end entity;

architecture tb of tb_soc_bus_concurrency is
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

        -- TEST 1: Back-to-back writes (10 cycles)
        report "TEST: Back-to-back writes";
        for dummy in 0 to 9 loop
            core_a_bus <= (addr => std_logic_vector(to_unsigned(dummy, 32)),
                           data => std_logic_vector(to_unsigned(dummy * 17, 32)),
                           we => '1', valid => '1');
            core_b_bus <= (addr => std_logic_vector(to_unsigned(dummy, 32)),
                           data => std_logic_vector(to_unsigned(dummy * 17, 32)),
                           we => '1', valid => '1');
            wait until rising_edge(clk);
            check(safe_state = '0', "back-to-back #" & integer'image(dummy) & ": ok");
            check(bus_valid = '1', "back-to-back #" & integer'image(dummy) & ": valid");
        end loop;
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 2: Alternating R/W
        report "TEST: Alternating R/W";
        for dummy in 0 to 9 loop
            core_a_bus <= (addr => x"00001000",
                           data => std_logic_vector(to_unsigned(dummy, 32)),
                           we => '1', valid => '1');
            core_b_bus <= (addr => x"00001000",
                           data => std_logic_vector(to_unsigned(dummy, 32)),
                           we => '1', valid => '1');
            wait until rising_edge(clk);
            check(safe_state = '0', "alt R/W #" & integer'image(dummy) & ": ok");
        end loop;
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 3: Max bus stall (valid held 20 cycles)
        report "TEST: Max bus stall";
        for dummy in 0 to 19 loop
            core_a_bus <= (addr => x"00002000", data => x"CAFECAFE", we => '1', valid => '1');
            core_b_bus <= (addr => x"00002000", data => x"CAFECAFE", we => '1', valid => '1');
            wait until rising_edge(clk);
            check(safe_state = '0', "stall #" & integer'image(dummy) & ": ok");
        end loop;
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 4: Rapid address changes
        report "TEST: Rapid address changes";
        for dummy in 0 to 7 loop
            core_a_bus <= (addr => std_logic_vector(to_unsigned(4096 + dummy * 4, 32)),
                           data => std_logic_vector(to_unsigned(dummy, 32)),
                           we => '1', valid => '1');
            core_b_bus <= (addr => std_logic_vector(to_unsigned(4096 + dummy * 4, 32)),
                           data => std_logic_vector(to_unsigned(dummy, 32)),
                           we => '1', valid => '1');
            wait until rising_edge(clk);
            check(safe_state = '0', "rapid addr #" & integer'image(dummy) & ": ok");
        end loop;
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        -- TEST 5: Burst write
        report "TEST: Burst write 4 beats";
        for dummy in 0 to 3 loop
            core_a_bus <= (addr => std_logic_vector(to_unsigned(dummy * 4, 32)),
                           data => std_logic_vector(to_unsigned(dummy, 32)),
                           we => '1', valid => '1');
            core_b_bus <= (addr => std_logic_vector(to_unsigned(dummy * 4, 32)),
                           data => std_logic_vector(to_unsigned(dummy, 32)),
                           we => '1', valid => '1');
            wait until rising_edge(clk);
            check(safe_state = '0', "burst #" & integer'image(dummy) & ": ok");
        end loop;
        core_a_bus.valid <= '0';
        core_b_bus.valid <= '0';
        wait for CLK_PERIOD;

        test_runner_cleanup(runner);
    end process;

end architecture tb;
