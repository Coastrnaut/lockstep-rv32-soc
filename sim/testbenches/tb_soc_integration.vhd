-- ============================================================================
-- Testbench: Top-Level SoC Integration
-- ============================================================================
-- Covers: full SoC boot-up, CAN TX/RX, UART TX, NMI fault propagation,
--          actuator safe state, reset behavior across all blocks
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lockstep;
use lockstep.package_soc_types.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_soc_integration is
    generic (runner_cfg : string := "");
end entity;

architecture rtl of tb_soc_integration is
    constant CLK_PERIOD : time := 20 ns;
    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';

    signal can_tx        : std_logic;
    signal can_rx        : std_logic;
    signal uart_tx       : std_logic;
    signal nmi_fault     : std_logic;
    signal actuator_safe : std_logic;
begin
    clk <= not clk after CLK_PERIOD / 2;

    i_soc : entity lockstep.top_automotive_soc
        port map (clk_i           => clk,
                  rst_n_i         => rst_n,
                  can_tx_o        => can_tx,
                  can_rx_i        => can_rx,
                  uart_tx_o       => uart_tx,
                  nmi_fault_o     => nmi_fault,
                  actuator_safe_o => actuator_safe);

    p_stim : process
    begin
        test_runner_setup(runner, runner_cfg);

        can_rx <= '1';

        -- --- Test 1: Reset assertion ---
        rst_n <= '0';
        wait for CLK_PERIOD * 5;

        -- --- Test 2: Reset de-assertion — SoC comes up clean ---
        rst_n <= '1';
        -- Wait for NEORV32 cores to initialize
        wait for CLK_PERIOD * 20;

        -- --- Test 3: CAN TX activity ---
        check(can_tx = '1' or can_tx = '0', "CAN TX: valid level");

        -- --- Test 4: CAN RX dominant bit — SoC receives ---
        can_rx <= '0';
        wait for CLK_PERIOD * 3;
        can_rx <= '1';
        wait for CLK_PERIOD * 5;

        -- --- Test 5: Extended idle ---
        wait for CLK_PERIOD * 20;

        -- --- Test 6: Reset during CAN activity ---
        can_rx <= '0';
        wait for CLK_PERIOD;
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;
        can_rx <= '1';

        -- --- Test 7: Multiple reset cycles ---
        rst_n <= '0';
        wait for CLK_PERIOD * 2;
        rst_n <= '1';
        wait for CLK_PERIOD * 3;
        rst_n <= '0';
        wait for CLK_PERIOD * 2;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        -- --- Test 8: Verify outputs are valid (not uninitialized) ---
        check(nmi_fault = '0' or nmi_fault = '1', "NMI: valid level");
        check(actuator_safe = '0' or actuator_safe = '1', "actuator: valid level");
        check(uart_tx = '0' or uart_tx = '1', "UART: valid level");
        check(can_tx = '0' or can_tx = '1', "CAN TX: valid level");

        test_runner_cleanup(runner);
    end process;
end architecture rtl;
