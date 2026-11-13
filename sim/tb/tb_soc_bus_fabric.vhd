-- ============================================================================
-- Testbench: Bus Response Fabric
-- ============================================================================
-- HSI section 8.1 at the closest boundary: the real comparator, soc_bus_fabric
-- and ecc_data_ram, wired as in top_automotive_soc. Both cores' buses are the
-- same signal, so every request is compared and agreed on. The other slaves
-- drive a different constant all the time, so read data from anywhere but the
-- addressed slave shows up. A monitor checks every clock that an accepted
-- request gets exactly one of ACK and ERR in the next cycle, and nothing else
-- answers.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.tb_pkg.all;
  use work.tb_random_pkg.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity tb_soc_bus_fabric is
  generic (
    g_test : string := ""
  );
end entity tb_soc_bus_fabric;

architecture tb of tb_soc_bus_fabric is

  constant c_clk_period : time := 20 ns;

  constant c_bus_idle : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    sel   => "0000",
    we    => '0',
    valid => '0'
  );

  -- What the stand-in slaves answer, whether they are read or not
  constant c_wd_data   : std_logic_vector(31 downto 0) := x"0000A11D";
  constant c_can_data  : std_logic_vector(31 downto 0) := x"0000CA11";
  constant c_uart_data : std_logic_vector(31 downto 0) := x"0000BA0D";

  type t_addresses is array (natural range <>) of std_logic_vector(31 downto 0);

  -- HSI BUS-08: holes, neighbours of the mapped ranges, and aliases
  constant c_unmapped : t_addresses :=
  (
    x"00000000",
    x"1FFFFFFC",
    x"20040000",
    x"A0000000",
    x"40000000",
    x"400000FC",
    x"40000120",
    x"400001FC",
    x"4000020C",
    x"400002FC",
    x"40000330",
    x"400003FC",
    x"4000040C",
    x"40000500",
    x"40001400",
    x"C0000400",
    x"40010314",
    x"FFFFFFFC"
  );

  signal clk       : std_logic;
  signal rst_n     : std_logic;
  signal bus_rst_n : std_logic;
  signal req       : t_rv_bus;
  signal sys_bus   : t_rv_bus;
  signal bus_valid : std_logic;
  signal nmi_fault : std_logic;
  signal safe      : std_logic;
  signal ram_rdata : std_logic_vector(31 downto 0);
  signal ram_fatal : std_logic;
  signal rsp       : t_bus_rsp;

  -- From the monitor
  signal accepted   : natural;
  signal monitor_on : boolean;
  signal acks       : natural;
  signal errs       : natural;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(10 ms);

  i_comparator : entity lockstep.lockstep_comparator
    port map (
      clk_i         => clk,
      rst_n_syn_i   => rst_n,
      core_a_bus_i  => req,
      core_b_bus_i  => req,
      fatal_fault_i => ram_fatal,
      nmi_fault_o   => nmi_fault,
      safe_state_o  => safe,
      bus_valid_o   => bus_valid,
      sys_bus_o     => sys_bus
    );

  i_fabric : entity lockstep.soc_bus_fabric
    port map (
      clk_i        => clk,
      rst_n_i      => bus_rst_n,
      bus_i        => sys_bus,
      ram_rdata_i  => ram_rdata,
      wd_rdata_i   => c_wd_data,
      can_rdata_i  => c_can_data,
      uart_rdata_i => c_uart_data,
      ram_fatal_i  => ram_fatal,
      rsp_o        => rsp
    );

  i_ram : entity lockstep.ecc_data_ram
    port map (
      clk_i       => clk,
      rst_n_i     => rst_n,
      bus_rst_n_i => bus_rst_n,
      bus_i       => sys_bus,
      bus_ok_i    => bus_valid,
      rdata_o     => ram_rdata,
      dbe_fatal_o => ram_fatal
    );

  -- Every accepted request is answered once, in the next cycle, with one of ACK
  -- and ERR. Nothing else is. A reset in that cycle answers nothing.
  p_monitor : process is

    variable v_pending : boolean;

  begin

    wait until rising_edge(clk);

    -- Off only while a test breaks the fabric on purpose, for its own checks
    if (monitor_on) then
      if (v_pending and bus_rst_n = '1') then
        check((rsp.ack xor rsp.err) = '1', "exactly one of ACK and ERR for an accepted request");
      else
        check_equal(rsp.ack, '0', "no ACK without an accepted request");
        check_equal(rsp.err, '0', "no ERR without an accepted request");
      end if;

      if (rsp.err = '1') then
        check_equal(rsp.rdata, std_logic_vector'(x"00000000"), "no data with ERR");
      end if;

      -- Every response, and every clock without one, has even parity (HSI 8.6)
      check_equal(rsp.rpar, xor rsp.rdata, "read data parity");
    end if;

    if (rsp.ack = '1') then
      acks <= acks + 1;
    end if;

    if (rsp.err = '1') then
      errs <= errs + 1;
    end if;

    v_pending := sys_bus.valid = '1' and bus_rst_n = '1';

    if (v_pending) then
      accepted <= accepted + 1;
    end if;

  end process p_monitor;

  p_stim : process is

    alias ram_word  is << signal i_ram.r_word : std_logic_vector(71 downto 0) >>;
    alias commit    is << signal i_ram.w_commit : std_logic >>;
    alias f_ack     is << signal i_fabric.w_ack : std_logic >>;
    alias f_err     is << signal i_fabric.w_err : std_logic >>;
    alias f_pending is << signal i_fabric.r_pending : std_logic >>;
    alias f_target  is << signal i_fabric.r_target : std_logic_vector(4 downto 0) >>;
    alias f_rdata   is << signal i_fabric.w_rdata : std_logic_vector(31 downto 0) >>;

    variable v_rdata : std_logic_vector(31 downto 0);
    variable v_ack   : std_logic;
    variable v_err   : std_logic;
    variable v_rand  : t_random;

    -- A small window of the RAM, and what it should hold

    type t_model is array (0 to 15) of std_logic_vector(31 downto 0);

    variable v_model : t_model;
    variable v_index : natural;
    variable v_addr  : std_logic_vector(31 downto 0);
    variable v_data  : std_logic_vector(31 downto 0);
    variable v_sel   : std_logic_vector(3 downto 0);
    variable v_errs  : natural;
    variable v_store : std_logic;
    variable v_hole  : boolean;

    procedure reset_all is
    begin

      req       <= c_bus_idle;
      rst_n     <= '0';
      bus_rst_n <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n     <= '1';
      bus_rst_n <= '1';
      wait until rising_edge(clk);

    end procedure reset_all;

    -- One request for one clock, then the response cycle. Returns what the
    -- fabric answered.

    procedure transfer (
      constant addr : in std_logic_vector(31 downto 0);
      constant data : in std_logic_vector(31 downto 0);
      constant we   : in std_logic;
      constant sel  : in std_logic_vector(3 downto 0) := "1111"
    ) is
    begin

      req     <=
      (
        addr  => addr,
        data  => data,
        sel   => sel,
        we    => we,
        valid => '1'
      );
      wait until rising_edge(clk);
      req     <= c_bus_idle;
      wait until rising_edge(clk);
      v_rdata := rsp.rdata;
      v_ack   := rsp.ack;
      v_err   := rsp.err;

    end procedure transfer;

    procedure check_ack (
      constant addr     : in std_logic_vector(31 downto 0);
      constant expected : in std_logic_vector(31 downto 0)
    ) is
    begin

      transfer(addr, x"00000000", '0');
      check_equal(v_ack, '1', "ACK from " & to_hstring(addr));
      check_equal(v_err, '0', "no ERR from " & to_hstring(addr));
      check_equal(v_rdata, expected, "data from " & to_hstring(addr));

    end procedure check_ack;

    -- Merge the enabled byte lanes of data into a model word

    function merge (
      old  : std_logic_vector(31 downto 0);
      data : std_logic_vector(31 downto 0);
      sel  : std_logic_vector(3 downto 0)
    ) return std_logic_vector is

      variable v_word : std_logic_vector(31 downto 0);

    begin

      v_word := old;

      loop_lane : for lv_lane in 0 to 3 loop

        if (sel(lv_lane) = '1') then
          v_word(lv_lane * 8 + 7 downto lv_lane * 8) := data(lv_lane * 8 + 7 downto lv_lane * 8);
        end if;

      end loop loop_lane;

      return v_word;

    end function merge;

  begin

    test_runner_setup(g_test);
    v_rand.init_seed("tb_soc_bus_fabric");

    loop_while : while test_suite loop

      monitor_on <= true;
      reset_all;

      if run("each_mapped_target_answers_once_with_its_own_data") then
        transfer(x"20000000", x"CAFEF00D", '1');
        check_equal(v_ack, '1', "ACK for a RAM store");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "no data for a store");
        check_ack(x"20000000", x"CAFEF00D");
        transfer(x"2003FFFC", x"0BADBEEF", '1');
        check_ack(x"2003FFFC", x"0BADBEEF");
        check_ack(c_ecc_status_addr, x"00000000");
        check_ack(c_ecc_sbe_count_addr, x"00000000");
        check_ack(c_ecc_patrol_addr, x"00000000");
        check_ack(c_wd_kick_addr, c_wd_data);
        check_ack(c_wd_reset_src_addr, c_wd_data);
        check_ack(c_can_id_addr, c_can_data);
        check_ack(c_can_rx_irq_en_addr, c_can_data);
        check_ack(c_uart_tx_data_addr, c_uart_data);
        check_ack(c_uart_parity_addr, c_uart_data);

        -- Any byte of a register word is mapped (HSI BUS-02)
        check_ack(x"40000315", c_can_data);
        check_ack(x"40000403", c_uart_data);
        check_equal(errs, 0, "no ERR");
      elsif run("unmapped_addresses_answer_one_err_with_no_data_and_no_store") then
        transfer(x"20000000", x"5A5A5A5A", '1');

        loop_i : for lv_i in c_unmapped'range loop

          transfer(c_unmapped(lv_i), x"00000000", '0');
          check_equal(v_err, '1', "ERR for a load from " & to_hstring(c_unmapped(lv_i)));
          check_equal(v_ack, '0', "no ACK for a load from " & to_hstring(c_unmapped(lv_i)));
          transfer(c_unmapped(lv_i), x"FFFFFFFF", '1');
          check_equal(v_err, '1', "ERR for a store to " & to_hstring(c_unmapped(lv_i)));
          check_equal(v_ack, '0', "no ACK for a store to " & to_hstring(c_unmapped(lv_i)));

        end loop loop_i;

        wait for 1 ns;
        check_equal(errs, 2 * c_unmapped'length, "one ERR each");
        check_ack(x"20000000", x"5A5A5A5A");
        check_ack(x"2003FFFC", x"00000000");
        check_equal(nmi_fault, '0', "an unmapped address is not a fault");
      elsif run("double_bit_error_answers_err_and_the_next_request_is_denied") then
        transfer(x"20000008", x"12345678", '1');
        transfer(x"20000010", x"00000000", '1');

        -- A load, and a store presented in the cycle the uncorrectable word
        -- comes back, as soon as one could be
        req                  <=
        (
          addr  => x"20000008",
          data  => x"00000000",
          sel   => "1111",
          we    => '0',
          valid => '1'
        );
        wait until rising_edge(clk);
        req                  <=
        (
          addr  => x"20000010",
          data  => x"FFFFFFFF",
          sel   => "1111",
          we    => '1',
          valid => '1'
        );
        wait for 1 ns;
        ram_word(1 downto 0) <= force "11";
        wait for 1 ns;
        check_equal(ram_fatal, '1', "uncorrectable word");
        check_equal(rsp.err, '1', "ERR for the load");
        check_equal(rsp.ack, '0', "no ACK for the load");
        check_equal(rsp.rdata, std_logic_vector'(x"00000000"), "no data for the load");
        check_equal(sys_bus.valid, '0', "the store is not let through");
        wait until rising_edge(clk);
        ram_word(1 downto 0) <= release;
        req                  <= c_bus_idle;
        wait for 1 ns;
        check_equal(rsp.ack, '0', "no ACK for the denied store");
        check_equal(rsp.err, '0', "no ERR for the denied store either");
        check_equal(commit, '0', "the denied store does not commit");
        check_equal(bus_valid, '0', "the gate stays closed");
        check_equal(safe, '1', "safe state");

        loop_dummy : for lv_dummy in 1 to 4 loop

          wait until rising_edge(clk);
          check_equal(commit, '0', "nothing commits afterwards");

        end loop loop_dummy;

        check_equal(accepted, 3, "only the two setup stores and the load were accepted");
      elsif run("double_bit_error_on_a_partial_store_answers_err_and_writes_nothing") then
        transfer(x"20000008", x"12345678", '1');
        req                  <=
        (
          addr  => x"20000009",
          data  => x"00005A00",
          sel   => "0010",
          we    => '1',
          valid => '1'
        );
        wait until rising_edge(clk);
        req                  <= c_bus_idle;
        wait for 1 ns;
        ram_word(1 downto 0) <= force "11";
        wait for 1 ns;
        check_equal(rsp.err, '1', "ERR for the store");
        check_equal(rsp.ack, '0', "no ACK for the store");
        check_equal(commit, '0', "the store does not commit");
        wait until rising_edge(clk);
        ram_word(1 downto 0) <= release;

        -- The word is read back past the closed gate, as after a cold reset
        reset_all;
        check_ack(x"20000008", x"12345678");
      elsif run("warm_reset_in_the_response_cycle_answers_and_commits_nothing") then
        transfer(x"20000008", x"11111111", '1');
        req       <=
        (
          addr  => x"20000008",
          data  => x"22222222",
          sel   => "1111",
          we    => '1',
          valid => '1'
        );
        wait until rising_edge(clk);
        req       <= c_bus_idle;
        wait for 1 ns;
        bus_rst_n <= '0';
        wait for 1 ns;
        check_equal(rsp.ack, '0', "no ACK in reset");
        check_equal(rsp.err, '0', "no ERR in reset");
        check_equal(commit, '0', "no commit in reset");
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        bus_rst_n <= '1';
        wait until rising_edge(clk);
        check_ack(x"20000008", x"11111111");
      elsif run("back_to_back_requests_to_both_halves_of_a_word_each_land_once") then
        -- A request in every cycle, so each comes in the response cycle of the
        -- one before. The RAM writes before it reads, so the second store merges
        -- into the word the first one left.
        req      <=
        (
          addr  => x"20000014",
          data  => x"AAAAAAAA",
          sel   => "1111",
          we    => '1',
          valid => '1'
        );
        wait until rising_edge(clk);
        req.addr <= x"20000010";
        req.data <= x"BBBBBBBB";
        wait until rising_edge(clk);
        check_equal(rsp.ack, '1', "ACK for the upper half");
        req.addr <= x"20000011";
        req.data <= x"0000CC00";
        req.sel  <= "0010";
        wait until rising_edge(clk);
        check_equal(rsp.ack, '1', "ACK for the lower half");
        req.addr <= x"20000014";
        req.sel  <= "1111";
        req.we   <= '0';
        wait until rising_edge(clk);
        check_equal(rsp.ack, '1', "ACK for the byte");
        req.addr <= x"20000010";
        wait until rising_edge(clk);
        check_equal(rsp.ack, '1', "ACK for the upper load");
        check_equal(rsp.rdata, std_logic_vector'(x"AAAAAAAA"), "upper half");
        req      <= c_bus_idle;
        wait until rising_edge(clk);
        check_equal(rsp.ack, '1', "ACK for the lower load");
        check_equal(rsp.rdata, std_logic_vector'(x"BBBBCCBB"), "lower half, with the byte merged");
        wait for 1 ns;
        check_equal(accepted, 5, "five accepted");
        check_equal(acks, 5, "five ACKs");
      elsif run("random_traffic_is_answered_exactly_once_and_matches_a_model") then
        -- Fixed seed: the instance name. Loads and stores, mapped and unmapped,
        -- spaced or back to back, with any byte enables.
        v_model := (others => (others => '0'));
        v_errs  := 0;

        loop_request : for lv_request in 1 to 2000 loop

          v_index := v_rand.rand_int(0, 15);
          v_addr  := std_logic_vector(unsigned(c_ram_base_addr) + v_index * 4);
          v_data  := v_rand.rand_slv(32);
          v_sel   := v_rand.rand_slv(4);

          v_store := '0';

          if (v_rand.rand_int(0, 1) = 1) then
            v_store := '1';
          end if;

          v_hole := v_rand.rand_int(0, 9) = 0;

          if (v_hole) then
            v_addr := c_unmapped(v_rand.rand_int(c_unmapped'low, c_unmapped'high));
            v_errs := v_errs + 1;
          elsif (v_store = '1') then
            v_model(v_index) := merge(v_model(v_index), v_data, v_sel);
          end if;

          req <=
          (
            addr  => v_addr,
            data  => v_data,
            sel   => v_sel,
            we    => v_store,
            valid => '1'
          );
          wait until rising_edge(clk);

          if (v_rand.rand_int(0, 1) = 1) then
            req <= c_bus_idle;
            wait until rising_edge(clk);
          end if;

          -- Every load from the window is checked against the model, a clock
          -- after the strobe. Loads are made back to back with nothing else.
          req <=
          (
            addr  => std_logic_vector(unsigned(c_ram_base_addr) + v_index * 4),
            data  => x"00000000",
            sel   => "1111",
            we    => '0',
            valid => '1'
          );
          wait until rising_edge(clk);
          req <= c_bus_idle;
          wait until rising_edge(clk);
          check_equal(rsp.ack, '1', "ACK for the check load");
          check_equal(rsp.rdata, v_model(v_index), "word " & integer'image(v_index));

        end loop loop_request;

        wait until rising_edge(clk);
        check_equal(errs, v_errs, "one ERR for each unmapped request");
        check_equal(acks + errs, accepted, "one response for each accepted request");
        check_equal(nmi_fault, '0', "no fault");
      elsif run("parity_comes_from_each_slave_before_the_selection") then
        -- A bit of the selected data flipped after the selection does not move
        -- the parity, which was chosen from the slave's own data
        monitor_on <= false;

        loop_target : for lv_t in 0 to 3 loop

          case lv_t is

            when 0 =>

              transfer(x"20000010", x"00000001", '1');
              req <= (addr => x"20000010", data => x"00000000", sel => "1111", we => '0', valid => '1');

            when 1 =>

              req <= (addr => c_wd_status_addr, data => x"00000000", sel => "1111", we => '0', valid => '1');

            when 2 =>

              req <= (addr => c_can_id_addr, data => x"00000000", sel => "1111", we => '0', valid => '1');

            when others =>

              req <= (addr => c_uart_status_addr, data => x"00000000", sel => "1111", we => '0', valid => '1');

          end case;

          wait until rising_edge(clk);
          req               <= c_bus_idle;
          wait for 1 ns;
          check_equal(rsp.ack, '1', "a load, target " & integer'image(lv_t));
          check_equal(rsp.rpar, xor rsp.rdata, "parity as sent, target " & integer'image(lv_t));
          f_rdata(lv_t * 7) <= force not f_rdata(lv_t * 7);
          wait for 1 ns;
          check(rsp.rpar /= (xor rsp.rdata), "a flip after the selection breaks the parity, target " &
                integer'image(lv_t));
          f_rdata(lv_t * 7) <= release;
          wait until rising_edge(clk);

        end loop loop_target;

      elsif run("assertion_a_response_with_no_request_is_reported") then
        monitor_on <= false;
        expect_assertion("FORMAL FAIL: response with no request accepted");
        f_ack      <= force '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        f_ack      <= release;
        info("a response with no request is reported");
      elsif run("assertion_ack_and_err_together_are_reported") then
        monitor_on <= false;
        expect_assertion("FORMAL FAIL: ACK and ERR together");
        f_pending  <= force '1';
        f_target   <= force "00001";
        f_rdata    <= force x"00000000";
        f_ack      <= force '1';
        f_err      <= force '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        f_ack      <= release;
        f_err      <= release;
        f_rdata    <= release;
        f_target   <= release;
        f_pending  <= release;
        info("ACK and ERR together are reported");
      elsif run("assertion_read_data_with_err_is_reported") then
        monitor_on <= false;
        expect_assertion("FORMAL FAIL: read data with ERR");
        f_pending  <= force '1';
        f_target   <= force "00001";
        f_rdata    <= force x"12345678";
        f_ack      <= force '0';
        f_err      <= force '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        f_ack      <= release;
        f_err      <= release;
        f_rdata    <= release;
        f_target   <= release;
        f_pending  <= release;
        info("read data with ERR is reported");
      elsif run("assertion_a_response_target_not_one_hot_is_reported") then
        monitor_on <= false;
        expect_assertion("FORMAL FAIL: response target not one-hot");
        f_pending  <= force '1';
        f_target   <= force "00011";
        f_ack      <= force '0';
        f_err      <= force '0';
        wait until rising_edge(clk);
        wait for 1 ns;
        f_ack      <= release;
        f_err      <= release;
        f_target   <= release;
        f_pending  <= release;
        info("a target that is not one-hot is reported");
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
