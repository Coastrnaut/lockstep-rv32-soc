-- ============================================================================
-- Testbench: CAN Reception
-- ============================================================================
-- Plays frames from sim/scripts/can_frame_model.py onto the bus, as another node
-- would, and records what the controller drives during each bit. The model has
-- no part in the RTL, so a mistake shared by the sender and the receiver in the
-- RTL cannot hide here.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library lockstep;
  use lockstep.package_soc_types.all;

library work;
  use work.can_test_pkg.all;
  use work.can_rx_frames_pkg.all;

entity tb_can_receive is
  generic (
    runner_cfg : string := ""
  );
end entity tb_can_receive;

architecture tb of tb_can_receive is

  constant c_clk_period   : time     := 20 ns;
  constant c_clks_per_bit : positive := 100;
  constant c_bit_time     : time     := c_clk_period * c_clks_per_bit;

  -- The most that one edge may move the sample point, in clocks
  constant c_sjw : natural := c_clks_per_bit / 8;

  constant c_flag_bits : natural := 6;

  -- Rule of thumb for how long a bus takes to go idle after a reset or a frame
  constant c_idle_time : time := c_bit_time * 12;

  constant c_bus_idle : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0',
    sel   => "0000"
  );

  -- Bits of RX_STATUS
  constant c_frame_waiting : natural := 1;
  constant c_overrun       : natural := 2;

  -- A plain good frame out of the list, and one other
  constant c_frame       : t_rx_vector := c_rx_vectors(2);
  constant c_other_frame : t_rx_vector := c_rx_vectors(8);

  signal clk        : std_logic;
  signal rst_n      : std_logic;
  signal bus_i      : t_rv_bus;
  signal bus_ok     : std_logic;
  signal rdata      : std_logic_vector(31 downto 0);
  signal can_tx     : std_logic;
  signal can_busy   : std_logic;
  signal can_status : std_logic_vector(10 downto 0);
  signal can_irq    : std_logic;

  -- The bus: the DUT, the frames played into it, and a receiver that acknowledges
  signal can_bus    : std_logic;
  signal sender_tx  : std_logic;
  signal ack_tx     : std_logic;
  signal ack_enable : std_logic;

  -- Keeps the DUT from reaching the bus, as a failed transceiver would
  signal dut_blocked : std_logic;
  signal rx_done     : natural;
  signal rx_frame    : t_rx_frame;

  -- Clocks between the last two sample points
  signal sample_gap : natural;

  -- Lands a release on the very clock that a frame arrives
  signal release_on_arrival : boolean;

begin

  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(runner, 45 ms);

  dut : entity lockstep.automotive_can_controller
    generic map (
      g_clks_per_bit => c_clks_per_bit
    )
    port map (
      clk_i        => clk,
      rst_n_i      => rst_n,
      bus_i        => bus_i,
      bus_ok_i     => bus_ok,
      rdata_o      => rdata,
      can_tx_o     => can_tx,
      can_rx_i     => can_bus,
      can_busy_o   => can_busy,
      can_status_o => can_status,
      can_irq_o    => can_irq
    );

  can_bus <= (can_tx or dut_blocked) and sender_tx and ack_tx;

  i_node : entity work.can_test_node
    generic map (
      g_bit_time => c_bit_time
    )
    port map (
      bus_i        => can_bus,
      dut_tx_i     => can_tx,
      ack_enable_i => ack_enable,
      ack_o        => ack_tx,
      frame_o      => rx_frame,
      done_o       => rx_done
    );

  p_sample_gap : process is

    alias sample_tick is << signal dut.w_sample_tick : std_logic >>;

    variable v_count : natural;

  begin

    wait until rising_edge(clk);
    v_count := v_count + 1;

    if (sample_tick = '1') then
      sample_gap <= v_count;
      v_count    := 0;
    end if;

  end process p_sample_gap;

  p_release_on_arrival : process is

    alias frame_arriving is << signal dut.w_rx_valid : std_logic >>;
    alias buffer_release is << signal dut.w_buf_release : std_logic >>;

  begin

    wait until frame_arriving = '1' and release_on_arrival;
    buffer_release <= force '1';
    wait until rising_edge(clk);
    buffer_release <= release;

  end process p_release_on_arrival;

  p_stim : process is

    variable v_rdata : std_logic_vector(31 downto 0);
    variable v_dut   : std_logic_vector(1 to c_wire_length);
    variable v_gap   : natural;

    alias bus_off is << signal dut.r_bus_off : std_logic >>;

    procedure wait_clocks (
      constant count : in natural
    ) is
    begin

      for dummy in 1 to count loop

        wait until rising_edge(clk);

      end loop;

    end procedure wait_clocks;

    procedure reset_dut is
    begin

      bus_i     <= c_bus_idle;
      bus_ok    <= '1';
      sender_tx <= '1';
      rst_n     <= '0';
      wait_clocks(4);
      rst_n     <= '1';
      wait for c_idle_time;

    end procedure reset_dut;

    procedure write_bus (
      constant addr : in std_logic_vector(31 downto 0);
      constant data : in std_logic_vector(31 downto 0);
      constant sel  : in std_logic_vector(3 downto 0) := "1111"
    ) is
    begin

      bus_i <=
      (
        addr  => addr,
        data  => data,
        we    => '1',
        valid => '1',
        sel   => sel
      );
      wait until rising_edge(clk);
      bus_i <= c_bus_idle;

    end procedure write_bus;

    procedure read_bus (
      constant addr : in std_logic_vector(31 downto 0)
    ) is
    begin

      bus_i   <=
      (
        addr  => addr,
        data  => (others => '0'),
        we    => '0',
        valid => '1',
        sel   => "1111"
      );
      wait until rising_edge(clk);
      bus_i   <= c_bus_idle;
      wait until rising_edge(clk);
      v_rdata := rdata;

    end procedure read_bus;

    -- Each bit is recessive unless the wire says dominant, so that the bench can
    -- go on past the end of a wire to watch what the DUT does next

    procedure send_wire (
      constant wire     : in string;
      constant count    : in positive;
      constant bit_time : in time := c_bit_time
    ) is
    begin

      for index in 1 to count loop

        if (wire(index) = '0') then
          sender_tx <= '0';
        else
          sender_tx <= '1';
        end if;

        wait for bit_time * 7 / 8;
        v_dut(index) := can_tx;
        wait for bit_time / 8;

      end loop;

      sender_tx <= '1';

    end procedure send_wire;

    procedure send_bad_frame (
      constant index : in natural
    ) is
    begin

      send_wire(c_bad_vectors(index).wire, c_bad_vectors(index).flag_at + c_flag_bits + 2);

    end procedure send_bad_frame;

    procedure check_status (
      constant rec     : in natural;
      constant passive : in std_logic := '0'
    ) is
    begin

      read_bus(c_can_status_addr);
      check_equal(unsigned(v_rdata(31 downto 24)), rec, "REC");
      check_equal(v_rdata(1), passive, "error passive");

    end procedure check_status;

    procedure check_rx_status (
      constant expected : in natural;
      constant label_s  : in string
    ) is
    begin

      read_bus(c_can_rx_status_addr);
      check_equal(unsigned(v_rdata), expected, label_s);

    end procedure check_rx_status;

    procedure check_buffer (
      constant frame : in t_rx_vector
    ) is

      variable v_info : std_logic_vector(31 downto 0);

    begin

      read_bus(c_can_rx_id_addr);
      check_equal(v_rdata, "000" & frame.id, "RX_ID");

      v_info             := (others => '0');
      v_info(5)          := frame.extended;
      v_info(4)          := frame.remote;
      v_info(3 downto 0) := frame.dlc;
      read_bus(c_can_rx_info_addr);
      check_equal(v_rdata, v_info, "RX_INFO");

      read_bus(c_can_rx_data_addr);
      check_equal(v_rdata, frame.data(63 downto 32), "RX_DATA");
      read_bus(c_can_rx_data_hi_addr);
      check_equal(v_rdata, frame.data(31 downto 0), "RX_DATA_HI");

    end procedure check_buffer;

    procedure release_frame is
    begin

      write_bus(c_can_rx_status_addr, x"00000000");

    end procedure release_frame;

    -- Each bad frame adds 1, and each dominant bit after the flag adds 8

    procedure make_error_passive is
    begin

      for attempt in 1 to 15 loop

        send_wire(c_bad_vectors(0).wire, c_bad_vectors(0).length);
        sender_tx <= '0';
        wait for c_bit_time * (c_flag_bits + 2);
        sender_tx <= '1';
        wait for c_bit_time * 12;

      end loop;

      check_status(135, '1');

    end procedure make_error_passive;

    -- Clocks between sample points around one edge. offset says how far from the
    -- start of a bit the edge comes, and the bit before it is recessive.

    procedure measure_edge (
      constant offset : in integer
    ) is
    begin

      -- SOF, which the timer takes its phase from
      sender_tx <= '0';
      wait for c_bit_time;
      sender_tx <= '1';
      wait for c_bit_time + offset * c_clk_period;
      sender_tx <= '0';
      wait for c_bit_time;
      v_gap     := sample_gap;
      sender_tx <= '1';

    end procedure measure_edge;

    procedure check_gap (
      constant offset   : in integer;
      constant expected : in natural
    ) is
    begin

      reset_dut;
      measure_edge(offset);
      check_equal(v_gap, expected, "clocks between sample points");

    end procedure check_gap;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      ack_enable  <= '0';
      dut_blocked <= '0';

      if run("every_frame_is_received_and_acknowledged") then
        reset_dut;

        for index in c_rx_vectors'range loop

          send_wire(c_rx_vectors(index).wire, c_rx_vectors(index).length);

          for wire_bit in 1 to c_rx_vectors(index).length loop

            if (wire_bit = c_rx_vectors(index).ack_slot) then
              check_equal(v_dut(wire_bit), '0', "ACK in the ACK slot");
            else
              check_equal(v_dut(wire_bit), '1', "recessive outside the ACK slot");
            end if;

          end loop;

          check_rx_status(c_frame_waiting, "frame waiting");
          check_buffer(c_rx_vectors(index));
          release_frame;
          check_rx_status(0, "released");

        end loop;

        check_status(0);
      elsif run("a_sof_is_taken_once_at_any_phase_of_the_bit_timer") then
        reset_dut;

        -- Each frame starts one clock further round the timer than the last, so
        -- one of them lands on the clock of the sample point
        for phase in 0 to c_clks_per_bit - 1 loop

          wait_clocks(phase mod 7 + 1);
          send_wire(c_rx_vectors(0).wire, c_rx_vectors(0).length);
          check_buffer(c_rx_vectors(0));
          release_frame;
          check_status(0);

        end loop;

      elsif run("frames_follow_each_other_in_the_third_intermission_bit") then
        reset_dut;
        send_wire(c_frame.wire, c_frame.length - 1);
        check_buffer(c_frame);
        release_frame;
        send_wire(c_other_frame.wire, c_other_frame.length);
        check_buffer(c_other_frame);
        check_status(0);
      elsif run("fast_and_slow_senders_are_followed") then

        for speed in 0 to 3 loop

          reset_dut;

          for index in c_rx_vectors'range loop

            case speed is

              when 0 =>

                send_wire(c_rx_vectors(index).wire, c_rx_vectors(index).length, c_bit_time * 99 / 100);

              when 1 =>

                send_wire(c_rx_vectors(index).wire, c_rx_vectors(index).length, c_bit_time * 101 / 100);

              when 2 =>

                send_wire(c_rx_vectors(index).wire, c_rx_vectors(index).length, c_bit_time * 197 / 200);

              when others =>

                send_wire(c_rx_vectors(index).wire, c_rx_vectors(index).length, c_bit_time * 203 / 200);

            end case;

            check_buffer(c_rx_vectors(index));
            release_frame;

          end loop;

          check_status(0);

        end loop;

      elsif run("late_edge_moves_the_sample_point_later_up_to_a_limit") then
        check_gap(0, c_clks_per_bit);
        check_gap(5, c_clks_per_bit + 5);
        check_gap(c_sjw, c_clks_per_bit + c_sjw);
        check_gap(30, c_clks_per_bit + c_sjw);
      elsif run("early_edge_moves_the_sample_point_earlier_up_to_a_limit") then
        check_gap(-16, c_clks_per_bit - c_sjw);
        check_gap(-20, c_clks_per_bit - c_sjw);
      elsif run("only_one_edge_moves_the_sample_point_between_two_samples") then
        reset_dut;
        sender_tx <= '0';
        wait for c_bit_time;
        sender_tx <= '1';
        wait for c_bit_time + c_clk_period * 5;

        -- A glitch, and then the bit for real, later than the limit would allow
        sender_tx <= '0';
        wait for c_clk_period * 4;
        sender_tx <= '1';
        wait for c_clk_period * 4;
        sender_tx <= '0';
        wait for c_bit_time;
        sender_tx <= '1';
        check_equal(sample_gap, c_clks_per_bit + 5, "the second edge moved nothing");
      elsif run("no_edge_after_a_dominant_bit_moves_the_sample_point") then
        reset_dut;

        -- SOF, then a dominant bit, then a late fall after a recessive glitch
        sender_tx <= '0';
        wait for c_bit_time * 2 - c_clk_period * 20;
        sender_tx <= '1';
        wait for c_clk_period * 25;
        sender_tx <= '0';
        wait for c_bit_time;
        sender_tx <= '1';
        check_equal(sample_gap, c_clks_per_bit, "sampled dominant, so no bit is starting");
      elsif run("bad_frames_get_an_error_flag_in_the_right_bit") then

        for index in c_bad_vectors'range loop

          next when c_bad_vectors(index).flag_at = 0;

          reset_dut;
          send_bad_frame(index);

          for wire_bit in 1 to c_bad_vectors(index).flag_at + c_flag_bits + 1 loop

            if (wire_bit >= c_bad_vectors(index).flag_at and
                wire_bit < c_bad_vectors(index).flag_at + c_flag_bits) then
              check_equal(v_dut(wire_bit), '0', "six dominant bits");
            elsif (wire_bit = c_bad_vectors(index).ack_at) then
              check_equal(v_dut(wire_bit), '0', "the frame looked good as far as the ACK slot");
            else
              check_equal(v_dut(wire_bit), '1', "nothing else from the DUT");
            end if;

          end loop;

          check_status(1);
          check_rx_status(0, "the frame is not delivered");

        end loop;

      elsif run("dominant_last_bit_of_eof_is_not_an_error") then
        reset_dut;
        send_wire(c_bad_vectors(c_bad_vectors'high).wire, c_bad_vectors(c_bad_vectors'high).length + 16);

        for wire_bit in 1 to c_bad_vectors(c_bad_vectors'high).length + 16 loop

          if (wire_bit = c_bad_vectors(c_bad_vectors'high).ack_at) then
            check_equal(v_dut(wire_bit), '0', "ACK");
          else
            check_equal(v_dut(wire_bit), '1', "no error flag");
          end if;

        end loop;

        check_status(0);
        check_rx_status(c_frame_waiting, "the frame counts");
      elsif run("receiver_recovers_after_an_error_frame") then
        reset_dut;
        send_bad_frame(0);
        wait for c_bit_time * 11;
        send_wire(c_frame.wire, c_frame.length);
        check_buffer(c_frame);
        check_status(0);
      elsif run("dominant_after_the_flag_adds_8") then
        reset_dut;
        send_wire(c_bad_vectors(0).wire, c_bad_vectors(0).flag_at + c_flag_bits - 1);
        sender_tx <= '0';
        wait for c_bit_time * 2;
        sender_tx <= '1';
        wait for c_bit_time * 2;
        check_status(1 + 8);
      elsif run("recessive_after_the_flag_adds_nothing_more") then
        reset_dut;
        send_bad_frame(0);
        check_status(1);
      elsif run("error_passive_at_128_with_recessive_flags") then
        reset_dut;

        -- Nine a time, sixteen times, comes to 144
        for attempt in 1 to 16 loop

          send_wire(c_bad_vectors(0).wire, c_bad_vectors(0).length);
          sender_tx <= '0';
          wait for c_bit_time * (c_flag_bits + 2);
          sender_tx <= '1';
          wait for c_bit_time * 12;

          if (attempt = 14) then
            check_status(126);
          end if;

        end loop;

        check_status(144, '1');
        check_equal(can_status(9), '1', "error passive on the diagnostic port");

        send_wire(c_bad_vectors(0).wire, c_bad_vectors(0).flag_at + c_flag_bits + 2);

        for wire_bit in 1 to c_bad_vectors(0).flag_at + c_flag_bits + 1 loop

          check_equal(v_dut(wire_bit), '1', "nothing but recessive from a passive node");

        end loop;

        wait for c_bit_time * 11;
        check_status(145, '1');

        -- A good frame brings it back from above 127, and into the active state
        send_wire(c_frame.wire, c_frame.length);
        check_status(127);
      elsif run("error_count_stops_at_255") then
        reset_dut;

        for attempt in 1 to 30 loop

          send_wire(c_bad_vectors(0).wire, c_bad_vectors(0).length);
          sender_tx <= '0';
          wait for c_bit_time * (c_flag_bits + 2);
          sender_tx <= '1';
          wait for c_bit_time * 12;

        end loop;

        check_status(255, '1');
      elsif run("good_frames_take_the_error_count_down_one_at_a_time") then
        reset_dut;
        send_bad_frame(0);
        wait for c_bit_time * 11;
        send_bad_frame(1);
        wait for c_bit_time * 11;
        check_status(2);
        send_wire(c_frame.wire, c_frame.length);
        release_frame;
        check_status(1);
        send_wire(c_frame.wire, c_frame.length);
        release_frame;
        check_status(0);
        send_wire(c_frame.wire, c_frame.length);
        check_status(0);
      elsif run("an_ack_that_does_not_reach_the_bus_is_an_error") then
        reset_dut;
        dut_blocked <= '1';
        send_wire(c_frame.wire, c_frame.ack_slot + c_flag_bits + 2);
        check_equal(v_dut(c_frame.ack_slot), '0', "the DUT tried");
        check_equal(v_dut(c_frame.ack_slot + 1), '0', "and flagged the next bit");
        check_equal(v_dut(c_frame.ack_slot + c_flag_bits), '0', "for six bits");
        check_equal(v_dut(c_frame.ack_slot + c_flag_bits + 1), '1', "and stopped");
        check_status(1);
        check_rx_status(0, "the frame is not delivered");
      elsif run("full_buffer_keeps_the_first_frame_and_reports_the_second") then
        reset_dut;
        send_wire(c_frame.wire, c_frame.length);
        send_wire(c_other_frame.wire, c_other_frame.length);
        check_equal(v_dut(c_other_frame.ack_slot), '0', "still acknowledged");
        check_rx_status(c_frame_waiting + c_overrun, "overrun");
        check_buffer(c_frame);
        release_frame;
        check_rx_status(0, "both flags cleared");
        send_wire(c_other_frame.wire, c_other_frame.length);
        check_buffer(c_other_frame);
      elsif run("only_a_word_store_to_rx_status_releases_the_frame") then
        reset_dut;
        send_wire(c_frame.wire, c_frame.length);
        read_bus(c_can_rx_id_addr);
        check_rx_status(c_frame_waiting, "reads leave it");

        for pattern in 0 to 14 loop

          write_bus(c_can_rx_status_addr, x"00000000", std_logic_vector(to_unsigned(pattern, 4)));

        end loop;

        write_bus(c_can_rx_irq_en_addr, x"00000000");
        write_bus(x"C0000328", x"00000000");
        check_rx_status(c_frame_waiting, "other writes leave it");
        bus_ok <= '0';
        write_bus(c_can_rx_status_addr, x"00000000");
        bus_ok <= '1';
        check_rx_status(c_frame_waiting, "the safety gate blocks the release");
        release_frame;
        check_rx_status(0, "released");
      elsif run("a_frame_on_the_clock_of_a_release_is_kept") then
        reset_dut;
        send_wire(c_frame.wire, c_frame.length);
        check_rx_status(c_frame_waiting, "the first frame is waiting");
        release_on_arrival <= true;
        send_wire(c_other_frame.wire, c_other_frame.length);
        release_on_arrival <= false;
        check_rx_status(c_frame_waiting, "the second one took its place, with no overrun");
        check_buffer(c_other_frame);
      elsif run("a_received_frame_raises_the_interrupt_only_if_enabled") then
        reset_dut;
        send_wire(c_frame.wire, c_frame.length);
        check_equal(can_irq, '0', "off by default");
        read_bus(c_can_rx_irq_en_addr);
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "off by default");
        write_bus(c_can_rx_irq_en_addr, x"00000001");
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check_equal(can_irq, '1', "raised for the frame already waiting");
        read_bus(c_can_rx_irq_en_addr);
        check_equal(v_rdata, std_logic_vector'(x"00000001"), "enabled");
        release_frame;
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check_equal(can_irq, '0', "released");
        send_wire(c_frame.wire, c_frame.length);
        check_equal(can_irq, '1', "and raised for the next");
        write_bus(c_can_status_addr, x"00000000");
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check_equal(can_irq, '1', "a write to STATUS clears errors, not frames");
      elsif run("registers_answer_only_at_their_own_addresses") then
        reset_dut;

        -- Eight bytes, so that every one of these has something to show
        send_wire(c_other_frame.wire, c_other_frame.length);
        read_bus(x"C0000318");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "RX_ID is the whole address");
        read_bus(x"C000031C");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "RX_INFO is the whole address");
        read_bus(x"C0000320");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "RX_DATA is the whole address");
        read_bus(x"C0000324");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "RX_DATA_HI is the whole address");
        read_bus(x"C0000328");
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "RX_STATUS is the whole address");
        bus_ok <= '0';
        read_bus(c_can_rx_id_addr);
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "the gate blocks reads");
        bus_ok <= '1';
      elsif run("own_frames_are_not_delivered") then
        reset_dut;
        ack_enable <= '1';
        write_bus(c_can_id_addr, x"00000123");
        write_bus(c_can_dlc_addr, x"00000000");
        write_bus(c_can_tx_request_addr, x"00000001");
        wait until can_busy = '0' for c_bit_time * 150;
        check_equal(can_busy, '0', "sent");
        wait for c_bit_time * 3;
        check_rx_status(0, "nothing received");
        check_status(0);
      elsif run("errors_in_own_frames_are_left_to_the_transmitter") then
        reset_dut;
        ack_enable <= '1';

        -- Eight zero bytes have a recessive stuff bit in every sixth bit, so this
        -- makes a stuff error for the receiver and a bit error for the transmitter
        write_bus(c_can_id_addr, x"00000555");
        write_bus(c_can_dlc_addr, x"00000008");
        write_bus(c_can_tx_request_addr, x"00000001");
        wait until can_tx = '0' for c_bit_time * 2;
        wait for c_bit_time * 30;
        sender_tx <= '0';
        wait for c_bit_time * 7;
        sender_tx <= '1';
        wait until can_busy = '0' for c_bit_time * 300;
        check_equal(can_busy, '0', "sent in the end");
        wait for c_bit_time * 3;
        check_status(0);
        check_equal(unsigned(can_status(8 downto 0)), 7, "the transmitter counted it, and then a good frame");
        check_rx_status(0, "nothing received");
      elsif run("a_passive_nodes_failed_frame_is_not_delivered_to_itself") then
        reset_dut;
        make_error_passive;

        -- No ACK from anyone, and a recessive flag, so that nothing on the bus
        -- breaks up what looks like the end of a good frame
        write_bus(c_can_id_addr, x"00000123");
        write_bus(c_can_dlc_addr, x"00000000");
        write_bus(c_can_tx_request_addr, x"00000001");
        wait for c_bit_time * 200;
        check_rx_status(0, "nothing received");
      elsif run("a_passive_flag_is_timed_from_its_end") then
        reset_dut;
        make_error_passive;
        send_wire(c_bad_vectors(0).wire, c_bad_vectors(0).flag_at + c_flag_bits - 1);

        -- Five bits into the delimiter is no place for a frame to start
        wait for c_bit_time * 5;
        send_wire(c_frame.wire, c_frame.length);
        check_equal(v_dut(c_frame.ack_slot), '1', "no ACK");
        check_rx_status(0, "not taken for a SOF");
      elsif run("losing_arbitration_leaves_the_winner_received") then
        reset_dut;
        write_bus(c_can_id_addr, x"000007FF");
        write_bus(c_can_dlc_addr, x"00000000");
        write_bus(c_can_tx_request_addr, x"00000001");
        wait until can_tx = '0' for c_bit_time * 2;
        check_equal(can_tx, '0', "the DUT starts");
        send_wire(c_frame.wire, c_frame.length - 3);
        check_equal(v_dut(c_frame.ack_slot), '0', "and acknowledges the winner");
        check_rx_status(c_frame_waiting, "having received it");
        check_buffer(c_frame);
        ack_enable <= '1';
        wait until can_busy = '0' for c_bit_time * 150;
        check_equal(can_busy, '0', "its own frame gets through afterwards");
        check_status(0);
      elsif run("gate_down_stops_acknowledging_and_receiving") then
        reset_dut;
        bus_ok <= '0';
        send_wire(c_frame.wire, c_frame.length);
        check_equal(v_dut(c_frame.ack_slot), '1', "no ACK");
        bus_ok <= '1';
        check_rx_status(0, "nothing received");
      elsif run("a_bus_off_node_stays_off_the_bus") then
        reset_dut;
        bus_off <= force '1';
        wait for c_bit_time;
        send_wire(c_bad_vectors(0).wire, c_bad_vectors(0).flag_at + c_flag_bits);

        for wire_bit in 1 to c_bad_vectors(0).flag_at + c_flag_bits loop

          check_equal(v_dut(wire_bit), '1', "no error flag");

        end loop;

        wait for c_bit_time * 12;
        send_wire(c_frame.wire, c_frame.length);
        check_equal(v_dut(c_frame.ack_slot), '1', "no ACK");
        check_rx_status(0, "nothing received");
        bus_off <= release;
      elsif run("glitch_on_an_idle_bus_is_not_a_frame") then
        reset_dut;
        sender_tx <= '0';
        wait for c_clk_period * 20;
        sender_tx <= '1';
        wait for c_bit_time;
        send_wire(c_frame.wire, c_frame.length);
        check_buffer(c_frame);
        check_status(0);
      elsif run("nothing_is_received_until_the_bus_has_been_idle") then
        bus_i     <= c_bus_idle;
        bus_ok    <= '1';
        sender_tx <= '1';
        rst_n     <= '0';
        wait_clocks(4);
        rst_n     <= '1';

        -- A frame already under way when the node comes out of reset
        wait for c_bit_time * 5;
        send_wire(c_frame.wire, c_frame.length);
        check_rx_status(0, "the start of it was missed");
      elsif run("overload_flag_from_another_node_just_holds_off_the_next_frame") then
        -- In the first bit of the intermission, and in the second
        for intermission_bit in 1 to 2 loop

          reset_dut;
          send_wire(c_frame.wire, c_frame.length - 4 + intermission_bit);
          release_frame;
          sender_tx <= '0';
          wait for c_bit_time * c_flag_bits;
          sender_tx <= '1';
          wait for c_bit_time * 10;
          send_wire(c_other_frame.wire, c_other_frame.length);
          check_buffer(c_other_frame);
          check_status(0);

        end loop;

      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
