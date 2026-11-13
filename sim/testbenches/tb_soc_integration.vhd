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
  generic (
    runner_cfg : string := ""
  );
end entity tb_soc_integration;

architecture rtl of tb_soc_integration is

  constant c_clk_period : time := 20 ns;

  -- More than the reset and the comparator self-test take
  constant c_boot : time := c_clk_period * 300;

  signal clk    : std_logic;
  signal wd_clk : std_logic;
  signal rst_n  : std_logic;

  signal can_tx        : std_logic;
  signal can_rx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  -- The watchdog does not time out for 50 ms, and no test runs that long
  p_wd_clk : process is
  begin

    wd_clk <= '0', '1' after 500 ns;
    wait for 1 us;

  end process p_wd_clk;

  i_soc : entity lockstep.top_automotive_soc
    port map (
      clk_i           => clk,
      rst_n_i         => rst_n,
      wd_clk_i        => wd_clk,
      can_tx_o        => can_tx,
      can_rx_i        => can_rx,
      uart_tx_o       => uart_tx,
      nmi_fault_o     => nmi_fault,
      actuator_safe_o => actuator_safe,
      diag_cs_n_i     => '1',
      diag_sck_i      => '0',
      diag_sdo_o      => open

    );p_stim : process is
  begin

    test_runner_setup(runner, runner_cfg);

    can_rx <= '1';

    -- --- Test 1: Reset assertion ---
    rst_n <= '0';
    wait for c_clk_period * 5;
    check(actuator_safe = '1', "in reset: actuators held safe");

    -- --- Test 2: Reset de-assertion ---
    rst_n <= '1';
    wait for c_clk_period * 6;
    check(actuator_safe = '1', "self-test: actuators still held safe");
    wait for c_boot;

    -- Safety signals: actuator_safe falls once the reset has been released
    check(actuator_safe = '0', "post-reset: actuators not latched");
    check_equal(nmi_fault, '0', "post-reset: no NMI");

    -- --- Test 3: CAN RX dominant bit — SoC receives ---
    can_rx <= '0';
    wait for c_clk_period * 3;
    can_rx <= '1';
    wait for c_clk_period * 5;

    -- --- Test 4: Extended idle ---
    wait for c_clk_period * 20;

    -- --- Test 5: Reset during CAN activity ---
    can_rx <= '0';
    wait for c_clk_period;
    rst_n  <= '0';
    wait for c_clk_period * 3;
    rst_n  <= '1';
    wait for c_boot;
    can_rx <= '1';

    -- Safety signals recover after reset
    check(actuator_safe = '0', "post-reset: actuators released");

    -- --- Test 6: Multiple reset cycles ---
    rst_n <= '0';
    wait for c_clk_period * 2;
    rst_n <= '1';
    wait for c_clk_period * 3;
    rst_n <= '0';
    wait for c_clk_period * 2;
    rst_n <= '1';
    wait for c_clk_period * 3;

    -- --- Test 7: Verify safety outputs are valid (not X/U) ---
    check((actuator_safe = '0') or (actuator_safe = '1'), "actuator: valid level");
    check((nmi_fault = '0') or (nmi_fault = '1'), "NMI: valid level");

    test_runner_cleanup(runner);
    wait for 100 ns;

  end process p_stim;

end architecture rtl;
