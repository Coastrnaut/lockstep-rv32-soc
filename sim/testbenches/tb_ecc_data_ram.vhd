-- ============================================================================
-- Testbench: ECC Protected Data RAM
-- ============================================================================
-- Bit flips go into the word as it leaves the RAM, for the one clock that it is
-- checked, which is the RAM data bus of the verification specification.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_ecc_data_ram is
  generic (
    runner_cfg : string := ""
  );
end entity tb_ecc_data_ram;

architecture tb of tb_ecc_data_ram is

  constant c_clk_period : time := 20 ns;

  -- A flip in the word, and what it leaves in SYNDROME. Bit 2 of the data is at
  -- position 6, which the syndrome shows with bit 7 set for the failed parity.
  constant c_flip_one : std_logic_vector(71 downto 0) := x"000000000000000004";
  constant c_flip_two : std_logic_vector(71 downto 0) := x"000000000000000006";
  constant c_syndrome : natural                       := 16#86#;

  constant c_bus_idle : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0',
    sel   => "0000"
  );

  -- The last word in the RAM
  constant c_last_addr : std_logic_vector(31 downto 0) := x"2003FFFC";

  signal clk       : std_logic;
  signal rst_n     : std_logic;
  signal bus_i     : t_rv_bus;
  signal bus_ok    : std_logic;
  signal rdata     : std_logic_vector(31 downto 0);
  signal dbe_fatal : std_logic;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(runner, 10 ms);

  dut : entity lockstep.ecc_data_ram
    port map (
      clk_i       => clk,
      rst_n_i     => rst_n,
      bus_i       => bus_i,
      bus_ok_i    => bus_ok,
      rdata_o     => rdata,
      dbe_fatal_o => dbe_fatal
    );

  p_stim : process is

    alias ram_word is << signal dut.r_word : std_logic_vector(71 downto 0) >>;

    variable v_rdata : std_logic_vector(31 downto 0);
    variable v_fatal : std_logic;
    variable v_data  : std_logic_vector(31 downto 0);

    procedure cold_reset is
    begin

      rst_n <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n <= '1';

    end procedure cold_reset;

    -- The strobe, and then the clock the bus takes to answer, in which a store
    -- is written. mask flips bits of the word for that clock.

    procedure access_bus (
      constant addr : in std_logic_vector(31 downto 0);
      constant data : in std_logic_vector(31 downto 0);
      constant we   : in std_logic;
      constant sel  : in std_logic_vector(3 downto 0);
      constant mask : in std_logic_vector(71 downto 0)
    ) is
    begin

      bus_i <=
      (
        addr  => addr,
        data  => data,
        we    => we,
        valid => '1',
        sel   => sel
      );
      wait until rising_edge(clk);
      bus_i <= c_bus_idle;

      if (mask /= x"000000000000000000") then
        wait for 1 ns;
        ram_word <= force ram_word xor mask;
      end if;

      wait until rising_edge(clk);
      v_rdata := rdata;
      v_fatal := dbe_fatal;

      if (mask /= x"000000000000000000") then
        ram_word <= release;
      end if;

    end procedure access_bus;

    procedure write_bus (
      constant addr : in std_logic_vector(31 downto 0);
      constant data : in std_logic_vector(31 downto 0);
      constant sel  : in std_logic_vector(3 downto 0)  := "1111";
      constant mask : in std_logic_vector(71 downto 0) := x"000000000000000000"
    ) is
    begin

      access_bus(addr, data, '1', sel, mask);

    end procedure write_bus;

    procedure read_bus (
      constant addr : in std_logic_vector(31 downto 0);
      constant mask : in std_logic_vector(71 downto 0) := x"000000000000000000"
    ) is
    begin

      access_bus(addr, x"00000000", '0', "1111", mask);

    end procedure read_bus;

    procedure check_read (
      constant addr     : in std_logic_vector(31 downto 0);
      constant expected : in std_logic_vector(31 downto 0);
      constant label_s  : in string
    ) is
    begin

      read_bus(addr);
      check_equal(v_rdata, expected, label_s);

    end procedure check_read;

    procedure check_register (
      constant addr     : in std_logic_vector(31 downto 0);
      constant expected : in natural;
      constant label_s  : in string
    ) is
    begin

      read_bus(addr);
      check_equal(v_rdata, std_logic_vector(to_unsigned(expected, 32)), label_s);

    end procedure check_register;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      bus_i  <= c_bus_idle;
      bus_ok <= '1';
      cold_reset;

      if run("memory_starts_as_zeros_with_no_errors") then
        check_read(c_ram_base_addr, x"00000000", "first word");
        check_read(c_last_addr, x"00000000", "last word");
        check_register(c_ecc_sbe_count_addr, 0, "SBE_COUNT");
        check_register(c_ecc_status_addr, 0, "STATUS");
      elsif run("word_stores_read_back_all_over_the_ram") then
        write_bus(c_ram_base_addr, x"11111111");
        write_bus(x"20000004", x"22222222");
        write_bus(x"20000008", x"33333333");
        write_bus(x"20020000", x"44444444");
        write_bus(c_last_addr, x"55555555");
        check_read(c_ram_base_addr, x"11111111", "first word");
        check_read(x"20000004", x"22222222", "other half of the first word");
        check_read(x"20000008", x"33333333", "next word");
        check_read(x"20020000", x"44444444", "middle");
        check_read(c_last_addr, x"55555555", "last word");
        check_register(c_ecc_sbe_count_addr, 0, "no errors");
      elsif run("a_load_straight_after_a_store_sees_it") then
        -- The bus can start the next access as soon as the store's answer
        write_bus(x"20000010", x"CAFEF00D");
        read_bus(x"20000010");
        check_equal(v_rdata, std_logic_vector'(x"CAFEF00D"), "the new value");
      elsif run("byte_enables_merge_into_either_half") then

        for offset in 0 to 1 loop

          for pattern in 0 to 15 loop

            write_bus(x"20000100", x"AAAAAAAA");
            write_bus(x"20000104", x"BBBBBBBB");

            if (offset = 0) then
              write_bus(x"20000100", x"15141312", std_logic_vector(to_unsigned(pattern, 4)));
            else
              write_bus(x"20000104", x"15141312", std_logic_vector(to_unsigned(pattern, 4)));
            end if;

            -- The bytes not stored keep what they had
            v_data := x"15141312";

            for lane in 0 to 3 loop

              if (((pattern / 2 ** lane) mod 2) = 0) then
                if (offset = 0) then
                  v_data(lane * 8 + 7 downto lane * 8) := x"AA";
                else
                  v_data(lane * 8 + 7 downto lane * 8) := x"BB";
                end if;
              end if;

            end loop;

            if (offset = 0) then
              check_read(x"20000100", v_data, "stored half");
              check_read(x"20000104", x"BBBBBBBB", "other half");
            else
              check_read(x"20000104", v_data, "stored half");
              check_read(x"20000100", x"AAAAAAAA", "other half");
            end if;

          end loop;

        end loop;

      elsif run("addresses_outside_the_ram_do_nothing") then
        write_bus(c_ram_base_addr, x"12345678");
        write_bus(x"20040000", x"DEADBEEF");
        write_bus(x"1FFFFFFC", x"DEADBEEF");
        write_bus(x"A0000000", x"DEADBEEF");
        check_read(c_ram_base_addr, x"12345678", "the first word is not an alias");
        check_read(x"20040000", x"00000000", "just past the end");
        check_read(x"1FFFFFFC", x"00000000", "just before the start");
        check_read(x"A0000000", x"00000000", "top address bit");
      elsif run("read_data_is_zero_unless_reading") then
        write_bus(x"20000020", x"FFFFFFFF");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "nothing during a store");
        read_bus(x"20000020");
        wait until rising_edge(clk);
        check_equal(rdata, std_logic_vector'(x"00000000"), "nothing after the read");
      elsif run("safety_gate_blocks_access") then
        write_bus(x"20000030", x"12345678");
        bus_ok <= '0';
        write_bus(x"20000030", x"DEADBEEF");
        read_bus(x"20000030");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "no read data");
        bus_ok <= '1';
        check_read(x"20000030", x"12345678", "no store");
      elsif run("store_is_dropped_if_the_gate_closes_the_clock_after") then
        -- This is where a store that the cores disagree on stops
        write_bus(x"20000040", x"12345678");
        bus_i  <=
        (
          addr  => x"20000040",
          data  => x"DEADBEEF",
          we    => '1',
          valid => '1',
          sel   => "1111"
        );
        wait until rising_edge(clk);
        bus_i  <= c_bus_idle;
        bus_ok <= '0';
        wait until rising_edge(clk);
        bus_ok <= '1';
        check_read(x"20000040", x"12345678", "the store did not land");
      elsif run("every_single_bit_flip_on_a_load_is_corrected_and_counted") then
        write_bus(x"20000050", x"A5A55A5A");
        write_bus(x"20000054", x"0F0FF0F0");

        for index in 0 to 71 loop

          read_bus(x"20000050", std_logic_vector(shift_left(to_unsigned(1, 72), index)));
          check_equal(v_rdata, std_logic_vector'(x"A5A55A5A"), "low half after flipping bit " & integer'image(index));
          check_equal(v_fatal, '0', "not fatal");
          read_bus(x"20000054", std_logic_vector(shift_left(to_unsigned(1, 72), index)));
          check_equal(v_rdata, std_logic_vector'(x"0F0FF0F0"), "high half after flipping bit " & integer'image(index));
          check_equal(v_fatal, '0', "not fatal");

        end loop;

        check_register(c_ecc_sbe_count_addr, 72 * 2, "SBE_COUNT");
        check_register(c_ecc_dbe_count_addr, 0, "DBE_COUNT");
        check_register(c_ecc_status_addr, 1, "STATUS");
      elsif run("syndrome_register_holds_the_last_error") then
        write_bus(x"20000058", x"12345678");
        check_register(c_ecc_syndrome_addr, 0, "nothing yet");
        read_bus(x"20000058", c_flip_one);
        check_register(c_ecc_syndrome_addr, c_syndrome, "the flipped bit");
        check_read(x"20000058", x"12345678", "the next load is clean");
        check_register(c_ecc_syndrome_addr, c_syndrome, "it stays");
      elsif run("double_bit_flip_on_a_load_is_fatal_and_returns_nothing") then
        write_bus(x"20000060", x"12345678");
        read_bus(x"20000060", c_flip_two);
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "nothing returned");
        check_equal(v_fatal, '1', "fatal");
        wait for 1 ns;
        check_equal(dbe_fatal, '0', "only for that word");
        check_register(c_ecc_dbe_count_addr, 1, "DBE_COUNT");
        check_register(c_ecc_sbe_count_addr, 0, "SBE_COUNT");
        check_register(c_ecc_status_addr, 2, "STATUS");

        -- Data bits 1 and 2 are at positions 5 and 6, and parity still agrees
        check_register(c_ecc_syndrome_addr, 3, "SYNDROME");
      elsif run("single_bit_flip_during_a_store_is_repaired") then
        write_bus(x"20000070", x"11223344");
        write_bus(x"20000074", x"55667788", "1111", c_flip_one);
        check_register(c_ecc_sbe_count_addr, 1, "found");
        check_read(x"20000070", x"11223344", "the half that was flipped");
        check_read(x"20000074", x"55667788", "the half that was stored");
        check_register(c_ecc_sbe_count_addr, 1, "the word is clean again");
      elsif run("double_bit_flip_during_a_store_writes_nothing") then
        write_bus(x"20000078", x"11223344");
        write_bus(x"20000078", x"DEADBEEF", "1111", c_flip_two);
        check_equal(v_fatal, '1', "fatal");
        check_read(x"20000078", x"11223344", "the word is as it was");
      elsif run("status_keeps_the_worst_error") then
        write_bus(x"20000080", x"12345678");
        read_bus(x"20000080", c_flip_one);
        check_register(c_ecc_status_addr, 1, "single");
        read_bus(x"20000080", c_flip_two);
        check_register(c_ecc_status_addr, 2, "double");
        read_bus(x"20000080", c_flip_one);
        check_register(c_ecc_status_addr, 2, "still double");
      elsif run("error_counts_stop_at_their_limit") then
        write_bus(x"20000090", x"12345678");
        ram_word(2) <= force '1';

        for dummy in 1 to 16#10000# loop

          read_bus(x"20000090");

        end loop;

        ram_word(2) <= release;
        check_register(c_ecc_sbe_count_addr, 16#FFFF#, "does not wrap");
      elsif run("flips_outside_an_access_mean_nothing") then
        ram_word <= force x"000000000000000006";
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check_equal(dbe_fatal, '0', "not fatal");
        ram_word <= release;
        check_register(c_ecc_status_addr, 0, "not counted");
      elsif run("registers_read_only_at_their_own_address_and_ignore_writes") then
        write_bus(x"20000098", x"12345678");
        read_bus(x"20000098", c_flip_one);
        write_bus(c_ecc_sbe_count_addr, x"00000000");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "a write reads nothing back");
        check_register(c_ecc_sbe_count_addr, 1, "writing does not clear it");
        check_read(x"C0000100", x"00000000", "the whole address counts");
        bus_ok <= '0';
        read_bus(c_ecc_sbe_count_addr);
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "gated read");
        bus_ok <= '1';
      elsif run("cold_reset_clears_the_errors_but_not_the_ram") then
        write_bus(x"200000A0", x"12345678");
        read_bus(x"200000A0", c_flip_one);
        cold_reset;
        check_register(c_ecc_sbe_count_addr, 0, "SBE_COUNT");
        check_register(c_ecc_syndrome_addr, 0, "SYNDROME");
        check_register(c_ecc_status_addr, 0, "STATUS");
        check_read(x"200000A0", x"12345678", "the RAM");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
