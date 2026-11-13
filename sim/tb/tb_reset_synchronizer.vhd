-- ============================================================================
-- Testbench: Reset Synchroniser
-- ============================================================================
-- The stimulus drives the clock by hand, so that each reset edge lands exactly
-- where a test wants it between the clock edges.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

library work;
  use work.tb_pkg.all;

library lockstep;

entity tb_reset_synchronizer is
  generic (
    g_test : string := ""
  );
end entity tb_reset_synchronizer;

architecture tb of tb_reset_synchronizer is

  constant c_half_period : time := 10 ns;

  -- How far apart a reset edge and the next check are. It is shorter than
  -- c_half_period, so nothing here can be the work of a clock edge.
  constant c_settle : time := 1 ns;

  signal clk   : std_logic;
  signal rst_n : std_logic;

  -- The default of two stages
  signal rst_syn : std_logic;

  -- Five stages
  signal rst_long : std_logic;

begin

  i_dut : entity lockstep.reset_synchronizer
    port map (
      clk_i       => clk,
      rst_n_i     => rst_n,
      rst_n_syn_o => rst_syn
    );

  i_dut_long : entity lockstep.reset_synchronizer
    generic map (
      g_stages => 5
    )
    port map (
      clk_i       => clk,
      rst_n_i     => rst_n,
      rst_n_syn_o => rst_long
    );

  p_stim : process is

    alias long_stages is << signal i_dut_long.r_stages : std_logic_vector(4 downto 0) >>;

    procedure rising_clock is
    begin

      clk <= '1';
      wait for c_half_period;

    end procedure rising_clock;

    procedure falling_clock is
    begin

      clk <= '0';
      wait for c_half_period;

    end procedure falling_clock;

    procedure tick is
    begin

      rising_clock;
      falling_clock;

    end procedure tick;

    procedure set_reset (
      constant level : in std_logic
    ) is
    begin

      rst_n <= level;
      wait for c_settle;

    end procedure set_reset;

    -- From reset to fully released

    procedure run_to_released is
    begin

      set_reset('1');

      loop_dummy : for lv_dummy in 1 to 5 loop

        tick;

      end loop loop_dummy;

      check_equal(rst_syn, '1', "two stages released");
      check_equal(rst_long, '1', "five stages released");

    end procedure run_to_released;

  begin

    test_runner_setup(g_test);

    loop_while : while test_suite loop

      clk <= '0';
      set_reset('0');

      if run("output_falls_without_a_clock") then
        check_equal(rst_syn, '0', "low from the start");
        check_equal(rst_long, '0', "low from the start");
        run_to_released;
        set_reset('0');
        check_equal(rst_syn, '0', "fell with no clock edge");
        check_equal(rst_long, '0', "fell with no clock edge");
      elsif run("release_takes_one_rising_edge_per_stage") then
        set_reset('1');
        check_equal(rst_syn, '0', "the input alone releases nothing");

        loop_edge : for lv_edge in 1 to 5 loop

          check_equal(rst_long, '0', "five stages still held");
          rising_clock;

          if (lv_edge = 1) then
            check_equal(rst_syn, '0', "two stages held for one edge");
          else
            check_equal(rst_syn, '1', "two stages released by the second edge");
          end if;

          falling_clock;

        end loop loop_edge;

        check_equal(rst_long, '1', "five stages released by the fifth edge");
      elsif run("release_exactly_on_a_rising_edge_still_takes_every_stage") then
        -- docs/verification/specification.md section 2, item 3
        rst_n <= '1';
        clk   <= '1';
        wait for c_half_period;
        falling_clock;
        check_equal(rst_syn, '0', "that edge cannot be the last");
        check_equal(rst_long, '0', "that edge cannot be the last");
        rising_clock;
        check_equal(rst_syn, '1', "the next edge releases two stages");
        check_equal(rst_long, '0', "and five stages go on counting");
      elsif run("short_pulse_between_clock_edges_is_a_full_reset") then
        run_to_released;
        set_reset('0');
        set_reset('1');
        check_equal(rst_syn, '0', "the pulse is seen");
        tick;
        check_equal(rst_syn, '0', "and held after it ends");
        tick;
        check_equal(rst_syn, '1', "then released");
      elsif run("reset_during_a_release_starts_it_again") then
        set_reset('1');
        tick;
        set_reset('0');
        set_reset('1');
        tick;
        check_equal(rst_syn, '0', "the edge before the pulse no longer counts");
        tick;
        check_equal(rst_syn, '1', "released two edges after the pulse");
      elsif run("assertion_a_chain_released_out_of_order_is_reported") then
        -- A stage released before the one ahead of it in the chain: an upset
        -- that would release the reset early. The chain's own check reports it.
        set_reset('1');
        expect_assertion("FORMAL FAIL: reset chain released out of order");
        long_stages <= force "00010";
        tick;
        long_stages <= release;
        info("an out-of-order chain is reported");
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
