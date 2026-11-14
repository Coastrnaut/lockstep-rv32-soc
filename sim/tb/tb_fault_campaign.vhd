-- ============================================================================
-- Testbench: One Trial of the Fault Campaign (roadmap R2.3)
-- ============================================================================
-- Runs sim/scripts/soc_firmware.py on the SoC, with both trace ports on, and
-- injects one fault, chosen by the generics, at a fixed time. It records what
-- the outside world would see: when nmi_fault_o and actuator_safe_o rose, every
-- UART byte and CAN frame with its time, and when the cores' retirements first
-- differed. It writes those to fault_result.txt in its output folder, and
-- judges nothing: sim/scripts/fault_campaign.py classifies each trial against
-- a fault-free run. With the default generics this is that fault-free run.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library std;
  use std.textio.all;

library work;
  use work.tb_pkg.all;

library neorv32;
  use neorv32.neorv32_package.all;

library lockstep;
  use lockstep.package_soc_types.all;

library work;
  use work.can_test_pkg.all;

entity tb_fault_campaign is
  generic (
    g_test : string := "";
    -- The manifest's trial number
    g_trial : natural := 0;
    -- 0 for no fault; see p_inject
    g_site : natural := 0;
    g_bit  : natural := 0;
    -- 0 stuck at 0, 1 stuck at 1, 2 flipped
    g_kind : natural := 2;
    -- Clocks the fault lasts, 0 for the rest of the run
    g_duration : natural := 1;
    -- When, from the end of the cold reset
    g_inject_ns : natural := 50000;
    g_run_us    : natural := 700
  );
end entity tb_fault_campaign;

architecture tb of tb_fault_campaign is

  constant c_clk_period    : time := 20 ns;
  constant c_can_bit_time  : time := c_clk_period * 100;
  constant c_uart_bit_time : time := c_clk_period * 434;

  signal clk           : std_logic;
  signal wd_clk        : std_logic;
  signal rst_n         : std_logic;
  signal can_tx        : std_logic;
  signal uart_tx       : std_logic;
  signal nmi_fault     : std_logic;
  signal actuator_safe : std_logic;
  signal actuator_en   : std_logic;

  signal can_bus  : std_logic;
  signal ack_tx   : std_logic;
  signal rx_done  : natural;
  signal rx_frame : t_rx_frame;

  signal compared   : natural;
  signal mismatch   : std_logic;
  signal first      : natural;
  signal first_time : time;
  signal field      : string(1 to 9);

  -- What reached the pins, and when

  type t_bytes is array (1 to 32) of std_logic_vector(7 downto 0);

  type t_times is array (1 to 32) of time;

  signal uart_count : natural;
  signal uart_bytes : t_bytes;
  signal uart_times : t_times;
  signal nmi_seen   : boolean;
  signal nmi_time   : time;
  signal safe_seen  : boolean;
  signal safe_time  : time;
  signal can_times  : t_times;
  signal released   : boolean;

begin

  p_clk : process is
  begin

    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  p_wd_clk : process is
  begin

    wd_clk <= '0', '1' after 500 ns;
    wait for 1 us;

  end process p_wd_clk;

  test_runner_watchdog(50 ms);

  i_soc : entity lockstep.top_automotive_soc
    generic map (
      g_boot_mode => 2
    )
    port map (
      clk_i           => clk,
      rst_n_i         => rst_n,
      wd_clk_i        => wd_clk,
      can_tx_o        => can_tx,
      can_rx_i        => can_bus,
      uart_tx_o       => uart_tx,
      nmi_fault_o     => nmi_fault,
      actuator_safe_o => actuator_safe,
      actuator_en_o   => actuator_en,
      actuator_fb_i   => actuator_safe,
      diag_cs_n_i     => '1',
      diag_sck_i      => '0',
      diag_sdo_o      => open
    );

  can_bus <= can_tx and ack_tx;

  i_node : entity work.can_test_node
    generic map (
      g_bit_time => c_can_bit_time
    )
    port map (
      bus_i        => can_bus,
      dut_tx_i     => can_tx,
      ack_enable_i => '1',
      ack_o        => ack_tx,
      frame_o      => rx_frame,
      done_o       => rx_done
    );

  b_trace : block is

    alias trace_a is << signal ^.i_soc.w_core_a_trace : trace_port_t >>;
    alias trace_b is << signal ^.i_soc.w_core_b_trace : trace_port_t >>;

  begin

    i_compare : entity work.trace_compare
      port map (
        clk_i        => clk,
        trace_a_i    => trace_a,
        trace_b_i    => trace_b,
        compared_o   => compared,
        mismatch_o   => mismatch,
        first_o      => first,
        first_time_o => first_time,
        field_o      => field
      );

  end block b_trace;

  p_uart_rx : process is

    variable v_byte : std_logic_vector(7 downto 0);
    variable v_time : time;

  begin

    wait until uart_tx = '0';
    v_time := now;
    wait for c_uart_bit_time / 2;

    loop_i : for lv_i in 0 to 7 loop

      wait for c_uart_bit_time;
      v_byte(lv_i) := uart_tx;

    end loop loop_i;

    wait for c_uart_bit_time * 2;

    if (uart_count < uart_bytes'high) then
      uart_bytes(uart_count + 1) <= v_byte;
      uart_times(uart_count + 1) <= v_time;
      uart_count                 <= uart_count + 1;
    end if;

  end process p_uart_rx;

  p_pins : process (nmi_fault, actuator_safe, rx_done) is
  begin

    if (rising_edge(nmi_fault) and not nmi_seen and released) then
      nmi_seen <= true;
      nmi_time <= now;
    end if;

    if (rising_edge(actuator_safe) and not safe_seen and released) then
      safe_seen <= true;
      safe_time <= now;
    end if;

    if (rx_done'event and rx_done >= 1 and rx_done <= can_times'high) then
      can_times(rx_done) <= now;
    end if;

  end process p_pins;

  p_stim : process is

    alias a_wdata      is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.rf_wdata
      : std_ulogic_vector(31 downto 0) >>;
    alias b_wdata      is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.rf_wdata
      : std_ulogic_vector(31 downto 0) >>;
    alias a_fetch      is << signal i_soc.i_cpu_master.i_neorv32.imem_rsp : bus_rsp_t >>;
    alias b_fetch      is << signal i_soc.i_cpu_checker.i_neorv32.imem_rsp : bus_rsp_t >>;
    alias a_bus_data   is << signal i_soc.w_core_a_xbus_data : std_logic_vector(31 downto 0) >>;
    alias a_bus_addr   is << signal i_soc.w_core_a_xbus_addr : std_logic_vector(31 downto 0) >>;
    alias delayed_bus  is << signal i_soc.w_core_a_bus_late : t_rv_bus >>;
    alias cmp_state    is << signal i_soc.i_lockstep_gate.i_comparator_a.r_current_state : t_safe_state >>;
    alias bus_rsp      is << signal i_soc.w_bus_rsp : t_bus_rsp >>;
    alias ram_word     is << signal i_soc.i_ecc_ram.r_word : std_logic_vector(71 downto 0) >>;
    alias wd_counter   is << signal i_soc.i_watchdog_supervisor.i_watchdog.r_counter : unsigned(15 downto 0) >>;
    alias uart_shift   is << signal i_soc.i_safe_uart.r_tx_shift : std_logic_vector(10 downto 0) >>;
    alias can_pin      is << signal i_soc.i_automotive_can.r_tx_pin : std_logic >>;
    alias reset_stages is << signal i_soc.i_reset_sync.r_stages : std_logic_vector(1 downto 0) >>;
    alias selftest_res is << signal i_soc.i_comparator_self_test.r_result : t_safe_state >>;
    alias a_rd_we      is
      << signal i_soc.i_cpu_master.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_regfile_inst.rf_we
      : std_ulogic >>;
    alias b_rd_we      is
      << signal i_soc.i_cpu_checker.i_neorv32.core_complex_gen(0).core_complex_inst.cpu_inst.cpu_regfile_inst.rf_we
      : std_ulogic >>;
    alias a_bus        is << signal i_soc.w_core_a_bus : t_rv_bus >>;
    alias ram_read     is << signal i_soc.i_ecc_ram.r_read : std_logic >>;
    alias ram_write    is << signal i_soc.i_ecc_ram.r_write : std_logic >>;

    variable v_line : line;

    file f_result : text;

    -- The level to force: stuck at 0 or 1, or the opposite of what is there

    impure function level (
      now_value : std_logic
    ) return std_logic is
    begin

      if (g_kind = 0) then
        return '0';
      elsif (g_kind = 1) then
        return '1';
      end if;

      return not now_value;

    end function level;

    -- The bit's value just before the fault, for the result file

    impure function site_value return std_logic is
    begin

      case g_site is

        when 1 =>

          return a_wdata(g_bit mod 32);

        when 2 =>

          return a_fetch.data(g_bit mod 32);

        when 3 =>

          return a_bus_data(g_bit mod 32);

        when 4 =>

          return a_bus_addr(g_bit mod 32);

        when 5 =>

          return delayed_bus.data(g_bit mod 32);

        when 6 =>

          return cmp_state(g_bit mod 8);

        when 7 =>

          return bus_rsp.rdata(g_bit mod 32);

        when 8 | 9 =>

          return ram_word(g_bit mod 72);

        when 10 =>

          return wd_counter(g_bit mod 16);

        when 11 =>

          return uart_shift(g_bit mod 11);

        when 12 =>

          return can_pin;

        when 13 =>

          return reset_stages(g_bit mod 2);

        when 14 =>

          return selftest_res(g_bit mod 8);

        when 15 =>

          return b_wdata(g_bit mod 32);

        when 16 =>

          return a_bus_data(g_bit mod 32);

        when 17 =>

          return a_wdata(g_bit mod 32);

        when 18 =>

          return bus_rsp.rdata(g_bit mod 32);

        when 19 =>

          return ram_word(g_bit mod 72);

        when 20 =>

          return a_fetch.data(g_bit mod 32);

        when others =>

          return '-';

      end case;

    end function site_value;

    -- Wait for the site to be in use, so that the fault meets activity: the next
    -- register write, instruction fetch, store, bus response or RAM access.
    -- The other sites hold state all the time.

    procedure wait_for_activity is

      constant c_patience : time := 200 us;

    begin

      case g_site is

        when 1 | 17 =>

          wait until a_rd_we = '1' for c_patience;

        when 2 | 20 =>

          wait until a_fetch.ack = '1' for c_patience;

        when 3 | 16 =>

          wait until a_bus.valid = '1' and a_bus.we = '1' for c_patience;

        when 5 =>

          wait until delayed_bus.valid = '1' and delayed_bus.we = '1' for c_patience;

        when 7 | 18 =>

          -- The read data settles a delta cycle after ACK, from the selection
          -- that ACK drives: take the bit's value once it has, or a flip of a
          -- bit about to become 1 would force it to 1 and change nothing
          wait until bus_rsp.ack = '1' or bus_rsp.err = '1' for c_patience;
          wait for 1 ns;

        when 8 | 9 | 19 =>

          wait until ram_read = '1' or ram_write = '1' for c_patience;

        when 15 =>

          wait until b_rd_we = '1' for c_patience;

        when others =>

          null;

      end case;

    end procedure wait_for_activity;

    procedure inject is

      variable v_b : natural;

    begin

      case g_site is

        when 1 =>

          a_wdata(g_bit mod 32) <= force level(a_wdata(g_bit mod 32));

        when 2 =>

          a_fetch.data(g_bit mod 32) <= force level(a_fetch.data(g_bit mod 32));

        when 3 =>

          a_bus_data(g_bit mod 32) <= force level(a_bus_data(g_bit mod 32));

        when 4 =>

          a_bus_addr(g_bit mod 32) <= force level(a_bus_addr(g_bit mod 32));

        when 5 =>

          delayed_bus.data(g_bit mod 32) <= force level(delayed_bus.data(g_bit mod 32));

        when 6 =>

          cmp_state(g_bit mod 8) <= force level(cmp_state(g_bit mod 8));

        when 7 =>

          bus_rsp.rdata(g_bit mod 32) <= force level(bus_rsp.rdata(g_bit mod 32));

        when 8 =>

          ram_word(g_bit mod 72) <= force level(ram_word(g_bit mod 72));

        when 9 =>

          v_b                    := (g_bit + 1) mod 72;
          ram_word(g_bit mod 72) <= force level(ram_word(g_bit mod 72));
          ram_word(v_b)          <= force level(ram_word(v_b));

        when 10 =>

          wd_counter(g_bit mod 16) <= force level(wd_counter(g_bit mod 16));

        when 11 =>

          uart_shift(g_bit mod 11) <= force level(uart_shift(g_bit mod 11));

        when 12 =>

          can_pin <= force level(can_pin);

        when 13 =>

          reset_stages(g_bit mod 2) <= force level(reset_stages(g_bit mod 2));

        when 14 =>

          selftest_res(g_bit mod 8) <= force level(selftest_res(g_bit mod 8));

        when 15 =>

          b_wdata(g_bit mod 32) <= force level(b_wdata(g_bit mod 32));

        -- A burst: four neighbouring bits at once

        when 16 =>

          loop_burst : for lv_i in 0 to 3 loop

            v_b             := (g_bit + lv_i) mod 32;
            a_bus_data(v_b) <= force level(a_bus_data(v_b));

          end loop loop_burst;

        -- One disturbance in both cores at the same instant

        when 17 =>

          a_wdata(g_bit mod 32) <= force level(a_wdata(g_bit mod 32));
          b_wdata(g_bit mod 32) <= force level(b_wdata(g_bit mod 32));

        when 18 =>

          bus_rsp.rdata(g_bit mod 32) <= force level(bus_rsp.rdata(g_bit mod 32));

        -- Three neighbouring bits, beyond what SECDED corrects or detects

        when 19 =>

          loop_triple : for lv_i in 0 to 2 loop

            v_b           := (g_bit + lv_i) mod 72;
            ram_word(v_b) <= force level(ram_word(v_b));

          end loop loop_triple;

        when 20 =>

          a_fetch.data(g_bit mod 32) <= force level(a_fetch.data(g_bit mod 32));
          b_fetch.data(g_bit mod 32) <= force level(b_fetch.data(g_bit mod 32));

        when others =>

          null;

      end case;

    end procedure inject;

    procedure release_fault is
    begin

      case g_site is

        when 1 =>

          a_wdata(g_bit mod 32) <= release;

        when 2 =>

          a_fetch.data(g_bit mod 32) <= release;

        when 3 =>

          a_bus_data(g_bit mod 32) <= release;

        when 4 =>

          a_bus_addr(g_bit mod 32) <= release;

        when 5 =>

          delayed_bus.data(g_bit mod 32) <= release;

        when 6 =>

          cmp_state(g_bit mod 8) <= release;

        when 7 =>

          bus_rsp.rdata(g_bit mod 32) <= release;

        when 8 =>

          ram_word(g_bit mod 72) <= release;

        when 9 =>

          ram_word(g_bit mod 72)       <= release;
          ram_word((g_bit + 1) mod 72) <= release;

        when 10 =>

          wd_counter(g_bit mod 16) <= release;

        when 11 =>

          uart_shift(g_bit mod 11) <= release;

        when 12 =>

          can_pin <= release;

        when 13 =>

          reset_stages(g_bit mod 2) <= release;

        when 14 =>

          selftest_res(g_bit mod 8) <= release;

        when 15 =>

          b_wdata(g_bit mod 32) <= release;

        when 16 =>

          loop_burst : for lv_i in 0 to 3 loop

            a_bus_data((g_bit + lv_i) mod 32) <= release;

          end loop loop_burst;

        when 17 =>

          a_wdata(g_bit mod 32) <= release;
          b_wdata(g_bit mod 32) <= release;

        when 18 =>

          bus_rsp.rdata(g_bit mod 32) <= release;

        when 19 =>

          loop_triple : for lv_i in 0 to 2 loop

            ram_word((g_bit + lv_i) mod 72) <= release;

          end loop loop_triple;

        when 20 =>

          a_fetch.data(g_bit mod 32) <= release;
          b_fetch.data(g_bit mod 32) <= release;

        when others =>

          null;

      end case;

    end procedure release_fault;

    variable v_inject_time : time;
    variable v_before      : std_logic;

    -- A time in picoseconds, or -1 for one that never came

    impure function ps_or_none (
      seen : boolean;
      t    : time
    ) return string is
    begin

      if (not seen) then
        return "-1";
      end if;

      return integer'image(t / 1 ps);

    end function ps_or_none;

  begin

    test_runner_setup(g_test);

    loop_while : while test_suite loop

      if run("trial") then
        rst_n    <= '0';
        wait for c_clk_period * 5;
        rst_n    <= '1';
        released <= true;
        wait for g_inject_ns * 1 ns;

        -- Faults land just after a clock edge, so they last whole clocks
        wait until rising_edge(clk);
        wait for 1 ns;
        wait_for_activity;
        v_inject_time := now;
        v_before      := site_value;

        if (g_site /= 0) then
          inject;

          if (g_duration > 0) then

            loop_dummy : for lv_dummy in 1 to g_duration loop

              wait until rising_edge(clk);

            end loop loop_dummy;

            wait for 1 ns;
            release_fault;
          end if;
        end if;

        -- The run ends g_run_us after the cold reset
        wait for g_run_us * 1 us - (now - c_clk_period * 5);

        file_open(f_result, "fault_result.txt", write_mode);
        write(v_line, "trial=" & integer'image(g_trial) & " site=" & integer'image(g_site) &
              " bit=" & integer'image(g_bit) & " kind=" & integer'image(g_kind) &
              " duration=" & integer'image(g_duration) &
              " inject_ps=" & integer'image(v_inject_time / 1 ps) &
              " before=" & std_logic'image(v_before));
        writeline(f_result, v_line);
        write(v_line, "nmi_ps=" & ps_or_none(nmi_seen, nmi_time) & " safe_ps=" & ps_or_none(safe_seen, safe_time));
        writeline(f_result, v_line);

        if (mismatch = '1') then
          write(v_line, "trace_ps=" & integer'image(first_time / 1 ps) & " trace_order=" &
                integer'image(first) & " trace_field=" & field);
        else
          write(v_line, string'("trace_ps=-1"));
        end if;

        writeline(f_result, v_line);
        write(v_line, "retired=" & integer'image(compared));
        writeline(f_result, v_line);

        loop_i_2 : for lv_i in 1 to uart_count loop

          write(v_line, "uart " & integer'image(uart_times(lv_i) / 1 ps) & " " &
                to_hstring(uart_bytes(lv_i)));
          writeline(f_result, v_line);

        end loop loop_i_2;

        loop_i_3 : for lv_i in 1 to rx_done loop

          exit when lv_i > can_times'high;
          write(v_line, "can " & integer'image(can_times(lv_i) / 1 ps));
          writeline(f_result, v_line);

        end loop loop_i_3;

        if (rx_done > 0) then
          write(v_line, "can_frame id=" & to_hstring(rx_frame.id) & " dlc=" & to_hstring(rx_frame.dlc) &
                " data=" & to_hstring(rx_frame.data) & " crc_ok=" &
                boolean'image(rx_frame.crc = rx_frame.crc_expected and not rx_frame.stuff_error));
          writeline(f_result, v_line);
        end if;

        file_close(f_result);
      end if;

    end loop loop_while;

    test_runner_cleanup;

  end process p_stim;

end architecture tb;
