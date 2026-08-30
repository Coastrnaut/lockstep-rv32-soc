-- ============================================================================
-- Testbench: CAN Controller — Frame TX + Safety Gate
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_can is
  generic (
    runner_cfg : string
  );
end entity tb_can;

architecture tb of tb_can is

  signal clk_i      : std_logic;
  signal rst_n_i    : std_logic;
  signal bus_i      : t_rv_bus;
  signal bus_ok_i   : std_logic;
  signal can_rx_i   : std_logic;
  signal can_tx_o   : std_logic;
  signal can_busy_o : std_logic;begin

  -- Clock: 10ns period
  p_clk : process is
  begin

    wait for 5 ns;
    clk_i <= not clk_i;

  end process p_clk;

  -- DUT
  uut : entity lockstep.automotive_can_controller
    port map (
      clk_i      => clk_i,
      rst_n_i    => rst_n_i,
      bus_i      => bus_i,
      bus_ok_i   => bus_ok_i,
      can_tx_o   => can_tx_o,
      can_rx_i   => can_rx_i,
      can_busy_o => can_busy_o

    ); -- Stimulus

  p_stim : process is
  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      -- ---- Reset ----
      rst_n_i  <= '0';
      bus_ok_i <= '1';
      can_rx_i <= '1';
      bus_i    <= (valid => '0', we => '0', addr => (others => '0'), data => (others => '0'));
      wait for 20 ns;  -- 2 clock cycles in reset

      -- ---- Release reset, wait for DUT to settle ----
      rst_n_i <= '1';
      wait until rising_edge(clk_i);
      wait until rising_edge(clk_i);

      -- ---- Test 1: Idle state ----
      wait for 0 ns;
      check(can_busy_o = '0', "CAN idle after reset");

      -- ---- Test 2: Mailbox write → TX starts → TX completes ----
      bus_i <=
      (
        valid => '1',
        we    => '1',
        addr  => (others => '0'),
        data  => x"7FF08000"
      );

      -- One clock edge for mailbox to load
      wait until rising_edge(clk_i);

      -- Clear bus
      bus_i <= (valid => '0', we => '0', addr => (others => '0'), data => (others => '0'));

      -- Wait for FSM to pick up mailbox and go busy
      wait for 100 ns;
      wait for 0 ns;
      check(can_busy_o = '1', "CAN busy after mailbox write");

      -- Wait for TX to complete (FSM returns to IDLE)
      timeout_wait : for dummy in 1 to 50 loop

        wait until rising_edge(clk_i);
        wait for 0 ns;

        if (can_busy_o = '0') then
          exit timeout_wait;
        end if;

      end loop;

      check(can_busy_o = '0', "CAN returns to idle after TX");

      -- ---- Test 3: Safety gate drops during TX ----
      bus_i <=
      (
        valid => '1',
        we    => '1',
        addr  => (others => '0'),
        data  => x"7FF08000"
      );
      wait until rising_edge(clk_i);
      bus_i <= (valid => '0', we => '0', addr => (others => '0'), data => (others => '0'));

      -- Wait for TX to start
      wait for 50 ns;
      wait for 0 ns;

      -- Drop safety gate
      bus_ok_i <= '0';
      wait for 0 ns;
      check(can_tx_o = '1', "CAN TX forced recessive on safety gate drop");

      -- Restore gate and wait for TX to finish
      bus_ok_i <= '1';
      wait for 100 ns;

    end loop;

    test_runner_cleanup(runner);
    wait for 100 ns;

  end process p_stim;

end architecture tb;
