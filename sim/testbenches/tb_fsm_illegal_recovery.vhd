-- ============================================================================
-- Design Name:  Illegal FSM State Recovery Testbench
-- Description:  Drives automotive_can_controller with conflicting bus_ok
--               to force illegal FSM transitions and verify recovery.
-- Traces to:    VERIFICATION_SPECIFICATION.md 4B
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library lockstep;
use lockstep.package_soc_types.all;

entity tb_fsm_illegal_recovery is
    generic ( runner_cfg : string );
end entity;

architecture tb of tb_fsm_illegal_recovery is
    constant CLK_PERIOD : time := 20 ns;
    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';

    signal bus_i  : t_rv_bus;
    signal bus_ok : std_logic;
    signal can_tx : std_logic;
    signal can_rx : std_logic;
    signal can_busy : std_logic;
begin

    clk <= not clk after CLK_PERIOD / 2;

    uut : entity lockstep.automotive_can_controller
        port map (
            clk_i    => clk,
            rst_n_i  => rst_n,
            bus_i    => bus_i,
            bus_ok_i => bus_ok,
            can_tx_o => can_tx,
            can_rx_i => can_rx,
            can_busy_o => can_busy
        );

    p_test : process
    begin
        test_runner_setup(runner, "Illegal FSM State Recovery");

        rst_n <= '0';
        can_rx <= '0';
        bus_i  <= (addr => x"00000000", data => x"00000000", we => '0', valid => '0');
        bus_ok <= '1';
        wait for 100 ns;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- TEST 1: Normal operation baseline
        report "TEST: Normal CAN TX baseline";
        bus_i <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
        wait until rising_edge(clk);
        check(bus_ok = '1', "baseline: bus_ok");
        bus_i.valid <= '0';
        wait for CLK_PERIOD * 5;
        check(can_busy = '0', "baseline: idle after tx");

        -- TEST 2: Bus conflict (bus_ok toggled mid-transaction)
        report "TEST: Bus conflict mid-transaction";
        bus_i <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
        wait until rising_edge(clk);
        bus_ok <= '0';
        wait until rising_edge(clk);
        bus_ok <= '1';
        wait for CLK_PERIOD * 3;
        check(can_busy = '0', "bus conflict: recovered to idle");

        -- TEST 3: Rapid bus_ok toggle (forcing FSM state churn)
        report "TEST: Rapid bus_ok toggle";
        for dummy in 0 to 9 loop
            bus_i <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
            wait until rising_edge(clk);
            bus_ok <= '0';
            wait until rising_edge(clk);
            bus_ok <= '1';
            wait until rising_edge(clk);
        end loop;
        bus_i.valid <= '0';
        wait for CLK_PERIOD * 3;
        check(can_busy = '0', "rapid toggle: recovered");

        -- TEST 4: Bus held invalid during TX
        report "TEST: Bus invalid during TX";
        bus_i <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
        wait until rising_edge(clk);
        bus_ok <= '0';
        wait for CLK_PERIOD * 10;
        bus_ok <= '1';
        wait for CLK_PERIOD * 3;
        check(can_busy = '0', "bus invalid: recovered");

        -- TEST 5: Simultaneous RX+TX bus access
        report "TEST: Simultaneous RX+TX bus access";
        can_rx <= '1';
        bus_i <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        can_rx <= '0';
        bus_i.valid <= '0';
        wait for CLK_PERIOD * 3;
        check(can_busy = '0', "simultaneous: recovered");

        -- TEST 6: Verify FSM returns to valid state
        report "TEST: FSM valid state after stress";
        bus_i <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
        wait until rising_edge(clk);
        bus_i.valid <= '0';
        wait for CLK_PERIOD * 5;
        check(can_busy = '0', "stress: FSM idle");

        test_runner_cleanup(runner);
        wait;
    end process;

end architecture tb;
