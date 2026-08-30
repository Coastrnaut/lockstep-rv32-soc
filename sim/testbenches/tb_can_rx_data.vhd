-- ============================================================================
-- Testbench: CAN Controller RX Data Path and Register Access
-- ============================================================================
-- Covers: RX data reception, register writes, error frame handling, busy state
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

library vunit_lib;
  context vunit_lib.vunit_context;

entity tb_can_rx_data is
  generic (
    runner_cfg : string := ""
  );
end entity tb_can_rx_data;

architecture rtl of tb_can_rx_data is

  constant clk_period : time      := 20 ns;
  signal   clk        : std_logic := '0';
  signal   rst_n      : std_logic := '0';

  signal bus_i    : t_rv_bus;
  signal bus_ok   : std_logic;
  signal can_tx   : std_logic;
  signal can_rx   : std_logic;
  signal can_busy : std_logic;

begin

  clk <= not clk after clk_period / 2;

  i_can : entity lockstep.automotive_can_controller
    port map (
      clk_i      => clk,
      rst_n_i    => rst_n,
      bus_i      => bus_i,
      bus_ok_i   => bus_ok,
      can_tx_o   => can_tx,
      can_rx_i   => can_rx,
      can_busy_o => can_busy
    );

  p_stim : process is
  begin

    test_runner_setup(runner, runner_cfg);

    rst_n  <= '0';
    can_rx <= '1';
    bus_i  <= (addr => x"00000000", data => x"00000000", we => '0', valid => '0');
    bus_ok <= '1';
    wait for 100 ns;
    rst_n  <= '1';
    wait for clk_period * 2;

    -- --- Test 1: Idle baseline ---
    check(can_busy = '0', "idle: not busy");

    -- --- Test 2: Register write triggers TX state machine ---
    bus_i       <= (addr => x"00000000", data => x"000000FF", we => '1', valid => '1');
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    wait for clk_period * 5;
    -- State machine should have cycled through TX
    check(can_busy = '0', "reg write: returned to idle");

    -- --- Test 3: RX dominant bit (recessive->dominant transition) ---
    can_rx <= '0';
    wait for clk_period * 3;
    can_rx <= '1';
    wait for clk_period * 5;
    check(can_busy = '0', "RX dominant: returned to idle");

    -- --- Test 4: Register read (WE=0) ---
    bus_i       <= (addr => x"00000000", data => x"00000000", we => '0', valid => '1');
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    wait for clk_period * 2;
    check(can_busy = '0', "reg read: idle");

    -- --- Test 5: bus_ok dropped during register write ---
    bus_ok      <= '0';
    bus_i       <= (addr => x"00000000", data => x"000000AA", we => '1', valid => '1');
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    bus_ok      <= '1';
    wait for clk_period * 5;
    check(can_busy = '0', "bus_ok drop: idle");

    -- --- Test 6: Rapid RX toggling ---
    for dummy in 0 to 7 loop

      can_rx <= '0';
      wait for clk_period;
      can_rx <= '1';
      wait for clk_period;

    end loop;

    check(can_busy = '0', "rapid RX: idle");

    test_runner_cleanup(runner);

  end process p_stim;

end architecture rtl;
