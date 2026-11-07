
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_fsm_illegal_recovery is
  generic (
    runner_cfg : string := ""
  );
end entity tb_fsm_illegal_recovery;

architecture tb of tb_fsm_illegal_recovery is

  constant clk_period     : time     := 20 ns;
  constant c_clks_per_bit : positive := 4;

  -- Longest frame: 135 bits
  constant c_max_frame_time : time := clk_period * c_clks_per_bit * 135;

  signal clk   : std_logic;
  signal rst_n : std_logic;

  signal bus_i    : t_rv_bus;
  signal bus_ok   : std_logic;
  signal can_tx   : std_logic;
  signal can_rx   : std_logic;
  signal can_busy : std_logic;begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after clk_period / 2;
    wait for clk_period;

  end process p_clk;

  uut : entity lockstep.automotive_can_controller
    generic map (
      g_clks_per_bit => c_clks_per_bit
    )
    port map (
      clk_i      => clk,
      rst_n_i    => rst_n,
      bus_i      => bus_i,
      bus_ok_i   => bus_ok,
      can_tx_o   => can_tx,
      can_rx_i   => can_rx,
      can_busy_o => can_busy

    );p_test : process is
  begin

    test_runner_setup(runner, runner_cfg);

    rst_n  <= '0';
    can_rx <= '0';
    bus_i  <= (addr => x"00000000", data => x"00000000", we => '0', valid => '0');
    bus_ok <= '1';
    wait for 100 ns;
    rst_n  <= '1';
    wait for clk_period * 2;

    -- TEST 1: Normal TX baseline (DLC=0)
    report "TEST: Normal CAN TX baseline";
    bus_i       <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    wait for clk_period * 10;
    check(can_busy = '1', "baseline: frame in progress");
    wait for c_max_frame_time;
    check(can_busy = '0', "baseline: idle after tx");

    -- TEST 2: Bus conflict mid-transaction abandons the frame
    report "TEST: Bus conflict mid-transaction";
    bus_i       <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    wait for clk_period * 10;
    check(can_busy = '1', "bus conflict: frame in progress");
    bus_ok      <= '0';
    wait until rising_edge(clk);
    bus_ok      <= '1';
    wait for clk_period * 2;
    check(can_busy = '0', "bus conflict: recovered to idle");

    -- TEST 3: Rapid bus_ok toggle
    report "TEST: Rapid bus_ok toggle";

    for dummy in 0 to 4 loop

      bus_i       <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
      wait until rising_edge(clk);
      bus_i.valid <= '0';
      wait for clk_period * 10;
      bus_ok      <= '0';
      wait until rising_edge(clk);
      bus_ok      <= '1';
      wait for clk_period * 2;
      check(can_busy = '0', "rapid toggle: recovered");

    end loop;

    -- TEST 4: Bus held invalid during TX
    report "TEST: Bus invalid during TX";
    bus_i       <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    wait for clk_period * 10;
    bus_ok      <= '0';
    wait for clk_period * 10;
    check(can_busy = '0', "bus invalid: frame abandoned");
    bus_ok      <= '1';
    wait for clk_period * 10;
    check(can_busy = '0', "bus invalid: recovered");

    -- TEST 5: Simultaneous RX+TX
    report "TEST: Simultaneous RX+TX bus access";
    can_rx      <= '1';
    bus_i       <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    wait for clk_period * 10;
    can_rx      <= '0';
    check(can_busy = '1', "simultaneous: RX does not stop TX");
    wait for c_max_frame_time;
    check(can_busy = '0', "simultaneous: recovered");

    -- TEST 6: FSM valid state after stress
    report "TEST: FSM valid state after stress";
    bus_i       <= (addr => x"00000000", data => x"00000000", we => '1', valid => '1');
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    wait for c_max_frame_time;
    check(can_busy = '0', "stress: FSM idle");

    test_runner_cleanup(runner);

  end process p_test;

end architecture tb;
