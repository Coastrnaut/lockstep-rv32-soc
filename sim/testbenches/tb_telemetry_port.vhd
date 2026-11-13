-- ============================================================================
-- Testbench: Diagnostic Telemetry Port
-- ============================================================================
-- An SPI controller reads the port at its fastest clock, a tenth of clk_i, and
-- slower, with the telemetry changing under it and a read cut short.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_telemetry_port is
  generic (
    runner_cfg : string := ""
  );
end entity tb_telemetry_port;

architecture tb of tb_telemetry_port is

  constant c_clk_period : time := 20 ns;

  -- The fastest SPI clock the port takes: a tenth of clk_i
  constant c_fast : time := c_clk_period * 10;

  -- Two records that differ in every bit
  constant c_pattern  : t_telemetry := x"8000_02A5_2000_0108_0000_1234_0003_0001_0007_0001";
  constant c_inverted : t_telemetry := not c_pattern;

  signal clk       : std_logic;
  signal rst_n     : std_logic;
  signal telemetry : t_telemetry;
  signal cs_n      : std_logic;
  signal sck       : std_logic;
  signal sdo       : std_logic;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(runner, 1 ms);

  i_dut : entity lockstep.telemetry_port
    port map (
      clk_i       => clk,
      rst_n_i     => rst_n,
      telemetry_i => telemetry,
      cs_n_i      => cs_n,
      sck_i       => sck,
      sdo_o       => sdo
    );

  p_stim : process is

    variable v_record : t_telemetry;

    -- Mode 0: the controller samples sdo on the rising edge of sck. bits is how
    -- many to read before chip select rises again.

    procedure spi_read (
      constant period : in time;
      constant bits   : in positive := c_telemetry_bits
    ) is
    begin

      v_record := (others => '0');
      cs_n     <= '0';
      wait for period;

      loop_i : for lv_i in 0 to bits - 1 loop

        v_record(c_telemetry_bits - 1 - lv_i) := sdo;
        sck                                   <= '1';
        wait for period / 2 - 1 ns;
        -- The port moves on after sck falls, so the bit holds for the whole
        -- high phase, and a controller may sample anywhere in it
        check_equal(sdo, v_record(c_telemetry_bits - 1 - lv_i), "sdo holds while sck is high");
        wait for 1 ns;
        sck <= '0';
        wait for period / 2;

      end loop loop_i;

      cs_n <= '1';
      wait for period;

    end procedure spi_read;

  begin

    test_runner_setup(runner, runner_cfg);

    loop_while : while test_suite loop

      cs_n      <= '1';
      sck       <= '0';
      telemetry <= c_pattern;
      rst_n     <= '0';
      wait for c_clk_period * 3;
      wait until rising_edge(clk);
      rst_n     <= '1';
      wait for c_clk_period * 3;

      if run("reads_the_record_at_its_fastest_clock") then
        spi_read(c_fast);
        check_equal(v_record, c_pattern, "every bit, first bit first");
      elsif run("reads_it_at_a_slow_clock_too") then
        spi_read(5 us);
        check_equal(v_record, c_pattern, "every bit");
      elsif run("a_read_is_a_snapshot_taken_when_chip_select_falls") then
        cs_n      <= '0';
        wait for c_fast;
        telemetry <= c_inverted;
        cs_n      <= '1';
        wait for c_fast;

        -- A new read takes the record as it is now, and holds it
        telemetry <= c_pattern;
        cs_n      <= '0';
        wait for c_fast;
        telemetry <= c_inverted;

        loop_i_2 : for lv_i in c_telemetry_bits - 1 downto 0 loop

          v_record(lv_i) := sdo;
          sck            <= '1';
          wait for c_fast / 2;
          sck            <= '0';
          wait for c_fast / 2;

        end loop loop_i_2;

        cs_n <= '1';
        check_equal(v_record, c_pattern, "the record as it was when chip select fell");
      elsif run("a_read_cut_short_starts_again_from_the_first_bit") then
        spi_read(c_fast, 37);
        check_equal(v_record(159 downto 123), c_pattern(159 downto 123), "the first 37 bits");
        spi_read(c_fast);
        check_equal(v_record, c_pattern, "the whole record again");
      elsif run("sdo_is_low_with_chip_select_high") then
        -- A read starts and stops at once, which leaves ones in the port
        telemetry <= (others => '1');
        cs_n      <= '0';
        wait for c_fast;
        check_equal(sdo, '1', "selected, the first bit");
        cs_n      <= '1';
        wait for c_fast;

        loop_i_3 : for lv_i in 1 to 20 loop

          sck <= not sck;
          wait for c_fast / 2;
          check_equal(sdo, '0', "low while not selected");

        end loop loop_i_3;

      elsif run("a_cold_reset_clears_a_read_in_progress") then
        cs_n  <= '0';
        wait for c_fast;
        check_equal(sdo, '1', "the first bit");
        rst_n <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check_equal(sdo, '0', "nothing out in reset");
        rst_n <= '1';
      end if;

    end loop loop_while;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
