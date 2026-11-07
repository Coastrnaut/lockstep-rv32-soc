-- ============================================================================
-- Testbench: CAN Controller — Frame TX + Safety Gate
-- ============================================================================
-- p_monitor is an independent CAN receiver on can_tx_o. It samples mid-bit on
-- its own timing, removes and checks stuff bits, and recomputes the CRC. That
-- CRC is tested against the published CRC-15/CAN check value, and whole frames
-- are compared with wire bits from sim/scripts/can_frame_model.py.
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

  constant c_clk_period   : time     := 10 ns;
  constant c_clks_per_bit : positive := 4;
  constant c_bit_time     : time     := c_clk_period * c_clks_per_bit;

  -- Worst case: 98 stuffed bits, 24 stuff bits and a 13 bit tail
  constant c_max_frame_bits : positive := 135;
  constant c_max_frame_time : time     := c_bit_time * c_max_frame_bits;

  constant c_bus_idle : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0'
  );

  -- What the independent receiver saw on can_tx_o

  type t_rx_frame is record
    id             : std_logic_vector(10 downto 0);
    flags          : std_logic_vector(2 downto 0);  -- RTR, IDE, r0
    dlc            : std_logic_vector(3 downto 0);
    data           : std_logic_vector(63 downto 0); -- First byte on the wire in 63:56
    crc            : std_logic_vector(14 downto 0);
    crc_expected   : std_logic_vector(14 downto 0);
    crc_delimiter  : std_logic;
    ack_slot       : std_logic;
    ack_delimiter  : std_logic;
    tail_recessive : natural;                       -- EOF and intermission
    busy_at_end    : boolean;
    stuff_error    : boolean;
    wire           : std_logic_vector(0 to c_max_frame_bits - 1);
    wire_length    : natural;
  end record t_rx_frame;

  constant c_empty_frame : t_rx_frame :=
  (
    id             => (others => '0'),
    flags          => (others => '0'),
    dlc            => (others => '0'),
    data           => (others => '0'),
    crc            => (others => '0'),
    crc_expected   => (others => '0'),
    crc_delimiter  => '0',
    ack_slot       => '0',
    ack_delimiter  => '0',
    tail_recessive => 0,
    busy_at_end    => false,
    stuff_error    => false,
    wire           => (others => '0'),
    wire_length    => 0
  );

  signal clk_i      : std_logic;
  signal rst_n_i    : std_logic;
  signal bus_i      : t_rv_bus;
  signal bus_ok_i   : std_logic;
  signal can_rx_i   : std_logic;
  signal can_tx_o   : std_logic;
  signal can_busy_o : std_logic;

  -- Receiver results: SOFs seen, and frames finished or given up on
  signal rx_starts : natural;
  signal rx_done   : natural;
  signal rx_frame  : t_rx_frame;

  -- Shift-register sequence from the Bosch CAN 2.0 specification

  function crc15_next (
    crc      : std_logic_vector(14 downto 0);
    data_bit : std_logic
  ) return std_logic_vector is

    variable v_crc : std_logic_vector(14 downto 0);

  begin

    v_crc := crc(13 downto 0) & '0';

    if ((data_bit xor crc(14)) = '1') then
      v_crc := v_crc xor std_logic_vector(to_unsigned(16#4599#, 15));
    end if;

    return v_crc;

  end function crc15_next;

begin

  -- Clock: 10ns period
  p_clk : process is
  begin

    -- "after" puts the rising edge ahead of stimulus resuming from "wait for".
    clk_i <= '0', '1' after c_clk_period / 2;
    wait for c_clk_period;

  end process p_clk;

  test_runner_watchdog(runner, 10 ms);

  -- DUT
  uut : entity lockstep.automotive_can_controller
    generic map (
      g_clks_per_bit => c_clks_per_bit
    )
    port map (
      clk_i      => clk_i,
      rst_n_i    => rst_n_i,
      bus_i      => bus_i,
      bus_ok_i   => bus_ok_i,
      can_tx_o   => can_tx_o,
      can_rx_i   => can_rx_i,
      can_busy_o => can_busy_o
    );

  -- ========================================================================
  -- Independent CAN receiver
  -- ========================================================================
  p_monitor : process is

    variable v_frame : t_rx_frame;
    variable v_crc   : std_logic_vector(14 downto 0);
    variable v_run   : natural;
    variable v_last  : std_logic;
    variable v_bit   : std_logic;

    procedure sample_wire (
      variable sampled : out std_logic
    ) is
    begin

      sampled                           := can_tx_o;
      v_frame.wire(v_frame.wire_length) := can_tx_o;
      v_frame.wire_length               := v_frame.wire_length + 1;

    end procedure sample_wire;

    procedure next_wire_bit (
      variable sampled : out std_logic
    ) is
    begin

      wait for c_bit_time;
      sample_wire(sampled);

    end procedure next_wire_bit;

    -- After 5 identical bits the next wire bit must be their complement

    procedure skip_stuff_bit is
    begin

      if (v_run = 5) then
        next_wire_bit(v_bit);

        if (v_bit = v_last) then
          v_frame.stuff_error := true;
        end if;

        v_last := v_bit;
        v_run  := 1;
      end if;

    end procedure skip_stuff_bit;

    procedure receive_field (
      variable field  : out std_logic_vector;
      constant in_crc : in boolean
    ) is
    begin

      for i in field'range loop

        skip_stuff_bit;
        exit when v_frame.stuff_error;
        next_wire_bit(v_bit);
        field(i) := v_bit;

        if (v_bit = v_last) then
          v_run := v_run + 1;
        else
          v_last := v_bit;
          v_run  := 1;
        end if;

        if (in_crc) then
          v_crc := crc15_next(v_crc, v_bit);
        end if;

      end loop;

    end procedure receive_field;

    procedure receive_frame is

      variable v_bytes : natural;

    begin

      v_frame := c_empty_frame;

      -- SOF: the falling edge starts the receiver's own bit timing
      wait for c_bit_time / 2;
      sample_wire(v_bit);
      v_crc  := crc15_next((others => '0'), v_bit);
      v_last := v_bit;
      v_run  := 1;

      receive_field(v_frame.id, true);
      receive_field(v_frame.flags, true);
      receive_field(v_frame.dlc, true);
      v_bytes              := minimum(to_integer(unsigned(v_frame.dlc)), 8);
      receive_field(v_frame.data(63 downto 64 - v_bytes * 8), true);
      v_frame.crc_expected := v_crc;
      receive_field(v_frame.crc, false);

      -- Stuffing also covers the bit after the last CRC bit
      skip_stuff_bit;

      if (v_frame.stuff_error) then
        return;
      end if;

      next_wire_bit(v_frame.crc_delimiter);
      next_wire_bit(v_frame.ack_slot);
      next_wire_bit(v_frame.ack_delimiter);

      for dummy in 1 to 10 loop

        next_wire_bit(v_bit);

        if (v_bit = '1') then
          v_frame.tail_recessive := v_frame.tail_recessive + 1;
        end if;

      end loop;

      v_frame.busy_at_end := can_busy_o = '1';

    end procedure receive_frame;

  begin

    wait until can_tx_o = '0';
    rx_starts <= rx_starts + 1;
    receive_frame;
    rx_frame  <= v_frame;
    rx_done   <= rx_done + 1;

  end process p_monitor;

  -- ========================================================================
  -- Stimulus
  -- ========================================================================
  p_stim : process is

    constant c_crc_check_input : string := "123456789";

    variable v_seen : natural;
    variable v_crc  : std_logic_vector(14 downto 0);
    variable v_sof  : time;
    variable v_edge : time;

    procedure reset_dut is
    begin

      rst_n_i  <= '0';
      bus_ok_i <= '1';
      can_rx_i <= '1';
      bus_i    <= c_bus_idle;
      wait for c_clk_period * 3;
      rst_n_i  <= '1';
      wait until rising_edge(clk_i);

    end procedure reset_dut;

    -- One-clock mailbox write: data(31:21) = ID, (20:17) = DLC, (15:0) = payload

    procedure write_mailbox (
      constant id      : in natural;
      constant dlc     : in natural;
      constant payload : in natural
    ) is

      constant c_id      : std_logic_vector(10 downto 0) := std_logic_vector(to_unsigned(id, 11));
      constant c_dlc     : std_logic_vector(3 downto 0)  := std_logic_vector(to_unsigned(dlc, 4));
      constant c_payload : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(payload, 16));

    begin

      bus_i <=
      (
        addr  => (others => '0'),
        data  => c_id & c_dlc & '0' & c_payload,
        we    => '1',
        valid => '1'
      );
      wait until rising_edge(clk_i);
      bus_i <= c_bus_idle;

    end procedure write_mailbox;

    procedure wait_for_frame is
    begin

      v_seen := v_seen + 1;

      if (rx_done < v_seen) then
        wait until rx_done >= v_seen for c_max_frame_time * 2;
      end if;

      check(rx_done >= v_seen, "frame finished on the wire");

    end procedure wait_for_frame;

    procedure check_frame (
      constant id      : in natural;
      constant dlc     : in natural;
      constant payload : in natural
    ) is

      constant c_payload : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(payload, 16));
      constant c_bytes   : natural                       := minimum(dlc, 8);

    begin

      wait_for_frame;
      check(not rx_frame.stuff_error, "no stuff error");
      check_equal(rx_frame.id, std_logic_vector(to_unsigned(id, 11)), "ID");
      check_equal(rx_frame.flags, std_logic_vector'("000"), "RTR, IDE and r0 dominant");
      check_equal(rx_frame.dlc, std_logic_vector(to_unsigned(dlc, 4)), "DLC");
      check_equal(
                  rx_frame.data,
                  std_logic_vector(shift_left(unsigned(c_payload & c_payload & c_payload & c_payload),
                                               64 - c_bytes * 8)),
                  "data bytes"
                );
      check_equal(rx_frame.crc, rx_frame.crc_expected, "CRC sequence");
      check_equal(rx_frame.crc_delimiter, '1', "CRC delimiter recessive");
      check_equal(rx_frame.ack_slot, '1', "transmitter leaves the ACK slot recessive");
      check_equal(rx_frame.ack_delimiter, '1', "ACK delimiter recessive");
      check_equal(rx_frame.tail_recessive, 10, "EOF and intermission recessive");
      check(rx_frame.busy_at_end, "busy through the last intermission bit");

    end procedure check_frame;

    procedure send_and_check (
      constant id      : in natural;
      constant dlc     : in natural;
      constant payload : in natural
    ) is
    begin

      write_mailbox(id, dlc, payload);
      check_frame(id, dlc, payload);
      wait until can_busy_o = '0' for c_bit_time;
      check(can_busy_o = '0', "idle after the frame");
      wait until rising_edge(clk_i);

    end procedure send_and_check;

    -- Expected bits come from sim/scripts/can_frame_model.py

    procedure check_wire (
      constant id       : in natural;
      constant dlc      : in natural;
      constant payload  : in natural;
      constant expected : in string
    ) is
    begin

      write_mailbox(id, dlc, payload);
      check_frame(id, dlc, payload);
      check_equal(to_string(rx_frame.wire(0 to rx_frame.wire_length - 1)), expected, "wire bits");
      wait until can_busy_o = '0' for c_bit_time;
      wait until rising_edge(clk_i);

    end procedure check_wire;

    -- Start a mostly dominant frame and stop on one of its dominant bits

    procedure start_dominant_frame is
    begin

      write_mailbox(16#000#, 8, 16#0000#);
      wait until can_tx_o = '0' for c_max_frame_time;
      wait for c_bit_time * 2;
      check(can_tx_o = '0', "TX dominant mid-frame");
      check(can_busy_o = '1', "busy mid-frame");

    end procedure start_dominant_frame;

    procedure check_no_more_traffic (
      constant label_text : in string
    ) is
    begin

      wait until can_tx_o = '0' for c_max_frame_time;
      check(can_tx_o = '1', label_text);
      check(can_busy_o = '0', "still idle");

    end procedure check_no_more_traffic;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      v_seen := 0;
      reset_dut;

      if run("idle_line_stays_recessive") then
        check(can_busy_o = '0', "idle after reset");
        check(can_tx_o = '1', "recessive after reset");

        -- Traffic from other nodes must not start a frame
        for dummy in 1 to 8 loop

          can_rx_i <= '0';
          wait for c_bit_time;
          can_rx_i <= '1';
          wait for c_bit_time;

        end loop;

        check_equal(rx_starts, 0, "no frame without a mailbox write");
        check(can_busy_o = '0', "idle without a mailbox write");
      elsif run("reference_crc_matches_published_check_value") then
        -- CRC-15/CAN in the reveng catalogue: check=0x059E over ASCII "123456789"
        v_crc := (others => '0');

        for i in c_crc_check_input'range loop

          for b in 7 downto 0 loop

            v_crc := crc15_next(v_crc, to_unsigned(character'pos(c_crc_check_input(i)), 8)(b));

          end loop;

        end loop;

        check_equal(v_crc, std_logic_vector(to_unsigned(16#059E#, 15)), "published check value");
      elsif run("frame_fields_for_every_dlc") then

        for dlc in 0 to 8 loop

          send_and_check(16#123#, dlc, 16#A55A#);
          send_and_check(16#6AA#, dlc, 16#1234#);

        end loop;

      elsif run("every_identifier_bit_reaches_the_wire") then

        for id_bit in 0 to 10 loop

          send_and_check(2 ** id_bit, 1, 16#00FF#);

        end loop;

      elsif run("dlc_above_8_sends_8_bytes") then

        for dlc in 9 to 15 loop

          send_and_check(16#123#, dlc, 16#1234#);

        end loop;

      elsif run("wire_bits_match_reference_model") then
        check_wire(
                   16#123#, 2, 16#A55A#,
                   "0001001000110000011010100101010110101001001010111001111111111111"
                 );
        check_wire(
                   16#000#, 8, 16#0000#,
                   "000001000001000001100000100000100000100000100000100000100000100000" &
                   "1000001000001000001000001000001000010100010110111111111111111"
                 );
        check_wire(
                   16#7EF#, 8, 16#FFFF#,
                   "011111010111100010001111101111101111101111101111101111101111101111" &
                   "10111110111110111110111110111101110001010000011111111111111"
                 );
        check_wire(
                   16#555#, 8, 16#AAAA#,
                   "010101010101000100010101010101010101010101010101010101010101010101" &
                   "0101010101010101011111001110011101111111111111"
                 );
        check_wire(
                   16#2AA#, 0, 16#0000#,
                   "0010101010100000100010000010011000111111111111111"
                 );
        check_wire(
                   16#123#, 15, 16#1234#,
                   "000100100011000111100010010001101000001100100011010000011001000110" &
                   "100000110010001101000111011000110101111111111111"
                 );
      elsif run("stuff_bit_follows_a_run_ending_on_the_last_crc_bit") then
        -- Dominant run: the last five CRC bits of this frame are all 0
        check_wire(
                   16#009#, 0, 16#0000#,
                   "0000010001001000001001111100000110000011111111111111"
                 );
        -- Recessive run: the last five CRC bits of this frame are all 1
        check_wire(
                   16#017#, 0, 16#0000#,
                   "00000100101110000010010100100001111101111111111111"
                 );
      elsif run("bits_last_exactly_one_bit_time") then
        write_mailbox(16#555#, 8, 16#AAAA#);
        wait until can_tx_o = '0' for c_max_frame_time;
        v_sof  := now;
        v_edge := now;

        while (can_busy_o = '1') loop

          wait on can_tx_o, can_busy_o;

          if (can_tx_o'event) then
            check_equal((now - v_edge) mod c_bit_time, 0 ns, "TX edge on a bit boundary");
            v_edge := now;
          end if;

        end loop;

        wait_for_frame;
        check_equal(now - v_sof, c_bit_time * rx_frame.wire_length, "busy for the whole frame");
      elsif run("back_to_back_frames_keep_intermission") then
        write_mailbox(16#123#, 2, 16#A55A#);
        wait until can_tx_o = '0' for c_max_frame_time;
        v_sof := now;
        wait until can_busy_o = '0' for c_max_frame_time;
        wait until rising_edge(clk_i);
        write_mailbox(16#321#, 2, 16#5AA5#);
        wait until can_tx_o = '0' for c_max_frame_time;
        check_frame(16#123#, 2, 16#A55A#);
        check(now - v_sof >= c_bit_time * rx_frame.wire_length, "second SOF after the first frame's intermission");
        check_frame(16#321#, 2, 16#5AA5#);
      elsif run("write_blocked_while_gate_low") then
        bus_ok_i <= '0';
        write_mailbox(16#123#, 2, 16#A55A#);
        bus_ok_i <= '1';
        wait for c_max_frame_time;
        check_equal(rx_starts, 0, "no frame from a blocked write");
        check(can_busy_o = '0', "idle after a blocked write");

        -- The mailbox stayed empty, so the next write goes through intact
        wait until rising_edge(clk_i);
        send_and_check(16#321#, 2, 16#5AA5#);
      elsif run("gate_drop_forces_recessive_and_abandons_frame") then
        start_dominant_frame;
        bus_ok_i <= '0';
        wait for 1 ns;
        check(can_tx_o = '1', "recessive without waiting for a clock");
        wait for c_clk_period * 2;
        check(can_busy_o = '0', "frame abandoned");

        bus_ok_i <= '1';
        check_no_more_traffic("no frame tail after the gate returns");
        check_equal(rx_starts, 1, "only the abandoned frame started");
        wait_for_frame;
        check(rx_frame.stuff_error, "a receiver rejects the cut-off frame");

        -- A new frame after the gate returns is complete and correct
        wait until rising_edge(clk_i);
        send_and_check(16#321#, 2, 16#5AA5#);
      elsif run("one_clock_gate_drop_leaves_no_glitch") then
        start_dominant_frame;
        wait until rising_edge(clk_i);
        bus_ok_i <= '0';
        wait until rising_edge(clk_i);
        bus_ok_i <= '1';
        check_no_more_traffic("no dominant bit after a one clock gate drop");
      elsif run("write_during_frame_is_ignored") then
        -- 1, 4, 9 ... 64 bits in: every field, including before DLC and data are read
        for step in 1 to 8 loop

          wait until rising_edge(clk_i);
          write_mailbox(16#123#, 8, 16#A55A#);
          wait for c_bit_time * step * step;
          wait until rising_edge(clk_i);
          write_mailbox(16#321#, 2, 16#5AA5#);
          check_frame(16#123#, 8, 16#A55A#);
          wait until can_busy_o = '0' for c_bit_time;
          check_no_more_traffic("second write not queued");
          check_equal(rx_starts, step, "one frame per mailbox write");

        end loop;

      elsif run("reset_during_frame_returns_to_idle") then
        start_dominant_frame;
        rst_n_i <= '0';
        wait for 1 ns;
        check(can_tx_o = '1', "recessive without waiting for a clock");
        wait for c_clk_period * 2;
        rst_n_i <= '1';
        check_no_more_traffic("no frame tail after reset");
        check_equal(rx_starts, 1, "only the interrupted frame started");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
