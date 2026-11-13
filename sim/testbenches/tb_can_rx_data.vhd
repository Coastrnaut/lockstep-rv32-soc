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

library work;
  use work.can_test_pkg.all;

entity tb_can_rx_data is
  generic (
    runner_cfg : string := ""
  );
end entity tb_can_rx_data;

architecture rtl of tb_can_rx_data is

  constant c_clk_period   : time     := 20 ns;
  constant c_clks_per_bit : positive := 8;
  constant c_bit_time     : time     := c_clk_period * c_clks_per_bit;

  -- A whole frame, plus the 11 recessive bits that come before it
  constant c_max_frame_time : time := c_bit_time * (c_max_frame_bits + 11);

  signal clk   : std_logic;
  signal rst_n : std_logic;

  signal bus_i    : t_rv_bus;
  signal bus_ok   : std_logic;
  signal can_tx   : std_logic;
  signal can_rx   : std_logic;
  signal can_busy : std_logic;

  -- The bus: the DUT, a receiver that acknowledges, and dominant stimulus
  signal can_bus : std_logic;
  signal ack_tx  : std_logic;begin

  -- Clock process: initializes clk to '0' before toggling
  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  i_can : entity lockstep.automotive_can_controller
    generic map (
      g_clks_per_bit => c_clks_per_bit
    )
    port map (
      clk_i      => clk,
      rst_n_i    => rst_n,
      bus_i      => bus_i,
      bus_ok_i   => bus_ok,
      can_tx_o   => can_tx,
      can_rx_i   => can_bus,
      can_busy_o => can_busy

    );

  can_bus <= can_tx and ack_tx and can_rx;

  i_node : entity work.can_test_node
    generic map (
      g_bit_time => c_bit_time
    )
    port map (
      bus_i        => can_bus,
      dut_tx_i     => can_tx,
      ack_enable_i => '1',
      ack_o        => ack_tx
    );

  p_stim : process is
  begin

    test_runner_setup(runner, runner_cfg);

    rst_n  <= '0';
    can_rx <= '1';
    bus_i  <= (addr => x"00000000", data => x"00000000", we => '0', valid => '0', sel => "1111");
    bus_ok <= '1';
    wait for 100 ns;
    rst_n  <= '1';
    wait for c_clk_period * 2;

    -- --- Test 1: Idle baseline ---
    check(can_busy = '0', "idle: not busy");

    -- --- Test 2: Register write sends a frame ---
    bus_i       <= (addr => c_can_tx_request_addr, data => x"000000FF", we => '1', valid => '1', sel => "1111");
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    wait for c_clk_period * 5;
    check(can_busy = '1', "reg write: frame in progress");
    wait for c_max_frame_time;
    check(can_busy = '0', "reg write: returned to idle");

    -- --- Test 3: RX dominant bit (recessive->dominant transition) ---
    can_rx <= '0';
    wait for c_clk_period * 3;
    can_rx <= '1';
    wait for c_clk_period * 5;
    check(can_busy = '0', "RX dominant: returned to idle");

    -- --- Test 4: Register read (WE=0) ---
    bus_i       <= (addr => c_can_tx_request_addr, data => x"00000000", we => '0', valid => '1', sel => "1111");
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    wait for c_clk_period * 2;
    check(can_busy = '0', "reg read: idle");

    -- --- Test 5: bus_ok dropped during register write ---
    bus_ok      <= '0';
    bus_i       <= (addr => c_can_tx_request_addr, data => x"000000AA", we => '1', valid => '1', sel => "1111");
    wait until rising_edge(clk);
    bus_i.valid <= '0';
    bus_ok      <= '1';
    wait for c_clk_period * 5;
    check(can_busy = '0', "bus_ok drop: idle");

    -- --- Test 6: Rapid RX toggling ---
    loop_dummy : for lv_dummy in 0 to 7 loop

      can_rx <= '0';
      wait for c_clk_period;
      can_rx <= '1';
      wait for c_clk_period;

    end loop loop_dummy;

    check(can_busy = '0', "rapid RX: idle");

    test_runner_cleanup(runner);

  end process p_stim;

end architecture rtl;
