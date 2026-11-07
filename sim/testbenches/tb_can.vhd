-- ============================================================================
-- Testbench: CAN Controller — Frame TX, Bus Access + Safety Gate
-- ============================================================================
-- can_test_node is an independent CAN receiver on the bus. Its CRC is tested
-- against the published CRC-15/CAN check value, and whole frames are compared
-- with wire bits from sim/scripts/can_frame_model.py. p_rival plays another
-- transmitter from those same wire bits, and the force signals inject bus
-- faults. Expected timings come from ISO 11898-1.
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

entity tb_can is
  generic (
    runner_cfg : string
  );
end entity tb_can;

architecture tb of tb_can is

  constant c_clk_period   : time     := 10 ns;
  constant c_clks_per_bit : positive := 8;
  constant c_bit_time     : time     := c_clk_period * c_clks_per_bit;

  -- A whole frame, plus the 11 recessive bits that come before it
  constant c_max_frame_time : time := c_bit_time * (c_max_frame_bits + 11);

  -- Transceiver and bus delay from can_tx_o back to can_rx_i
  constant c_loop_delay : time := c_clk_period;

  constant c_status_bus_off : natural := 10;
  constant c_status_passive : natural := 9;

  constant c_bus_idle : t_rv_bus :=
  (
    addr  => (others => '0'),
    data  => (others => '0'),
    we    => '0',
    valid => '0',
    sel   => "1111"
  );

  -- The frame most tests send, with positions in its wire bits counted from SOF
  constant c_id       : natural := 16#123#;
  constant c_dlc      : natural := 2;
  constant c_payload  : natural := 16#A55A#;
  constant c_wire     : string  := "0001001000110000011010100101010110101001001010111001111111111111";
  constant c_ack_slot : natural := 52;
  constant c_last_eof : natural := 60;
  constant c_ifs_1    : natural := 61;

  -- The tail of a frame from the CRC delimiter, with an error flag after the ACK slot
  constant c_tail_active_flag : string := "1100000011111";

  -- Bits from SOF to the next SOF after an error flag that follows the ACK slot
  constant c_retry_bits         : natural := c_ack_slot + 1 + 6 + 11;
  constant c_passive_retry_bits : natural := c_retry_bits + 8;

  -- 0x123 with 8 different data bytes
  constant c_wire_8_bytes : string := "0001001000110001000001010001001000100011001101000100010101010110011001110111100010001000010001101111111111111111";

  -- Wire bits of rival frames that beat 0x123 and lose to it
  constant c_rival_win  : string := "00010010001000001010101001010101101010001100010000011111111111111";
  constant c_rival_lose : string := "0001001001";

  signal clk_i        : std_logic;
  signal rst_n_i      : std_logic;
  signal bus_i        : t_rv_bus;
  signal bus_ok_i     : std_logic;
  signal can_rx_i     : std_logic;
  signal can_tx_o     : std_logic;
  signal can_busy_o   : std_logic;
  signal can_status_o : std_logic_vector(10 downto 0);
  signal rdata_o      : std_logic_vector(31 downto 0);
  signal can_irq_o    : std_logic;

  -- The bus and what else is on it
  signal can_bus         : std_logic;
  signal ack_tx          : std_logic;
  signal ack_enable      : std_logic;
  signal rival_tx        : std_logic;
  signal force_dominant  : std_logic;
  signal force_recessive : std_logic;

  -- Receiver results: SOFs seen, and frames finished or given up on
  signal rx_starts : natural;
  signal rx_done   : natural;
  signal rx_frame  : t_rx_frame;

  -- Dominant edges driven by the DUT
  signal tx_falls : natural;

  -- Wire bits for p_rival to send, started by toggling rival_go
  signal rival_wire   : string(1 to 2 * c_max_frame_bits);
  signal rival_length : natural;
  signal rival_go     : boolean;

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
      clk_i        => clk_i,
      rst_n_i      => rst_n_i,
      bus_i        => bus_i,
      bus_ok_i     => bus_ok_i,
      rdata_o      => rdata_o,
      can_tx_o     => can_tx_o,
      can_rx_i     => can_rx_i,
      can_busy_o   => can_busy_o,
      can_status_o => can_status_o,
      can_irq_o    => can_irq_o
    );

  -- A wired-AND bus. force_recessive stands for a broken RX path, so only the
  -- DUT reads it.
  can_bus  <= can_tx_o and ack_tx and rival_tx and not force_dominant;
  can_rx_i <= transport (can_bus or force_recessive) after c_loop_delay;

  i_node : entity work.can_test_node
    generic map (
      g_bit_time => c_bit_time
    )
    port map (
      bus_i        => can_bus,
      dut_tx_i     => can_tx_o,
      ack_enable_i => ack_enable,
      ack_o        => ack_tx,
      frame_o      => rx_frame,
      starts_o     => rx_starts,
      done_o       => rx_done
    );

  p_count_tx : process (can_tx_o) is
  begin

    if falling_edge(can_tx_o) then
      tx_falls <= tx_falls + 1;
    end if;

  end process p_count_tx;

  -- Another transmitter, playing back wire bits and then letting go of the bus
  p_rival : process is
  begin

    rival_tx <= '1';

    loop

      wait on rival_go;

      for i in 1 to rival_length loop

        if (rival_wire(i) = '0') then
          rival_tx <= '0';
        else
          rival_tx <= '1';
        end if;

        wait for c_bit_time;

      end loop;

      rival_tx <= '1';

    end loop;

  end process p_rival;

  -- ========================================================================
  -- Stimulus
  -- ========================================================================
  p_stim : process is

    constant c_crc_check_input : string := "123456789";

    variable v_seen  : natural;
    variable v_crc   : std_logic_vector(14 downto 0);
    variable v_sof   : time;
    variable v_edge  : time;
    variable v_end   : time;
    variable v_falls : natural;
    variable v_addr  : std_logic_vector(31 downto 0);
    variable v_rdata : std_logic_vector(31 downto 0);
    variable v_sel   : std_logic_vector(3 downto 0);

    impure function tec return natural is
    begin

      return to_integer(unsigned(can_status_o(8 downto 0)));

    end function tec;

    -- The last 13 bits the DUT drove, from the CRC delimiter to the third
    -- intermission bit of a complete frame

    impure function wire_tail return string is
    begin

      return to_string(rx_frame.wire(rx_frame.wire_length - 13 to rx_frame.wire_length - 1));

    end function wire_tail;

    procedure reset_dut is
    begin

      rst_n_i         <= '0';
      bus_ok_i        <= '1';
      bus_i           <= c_bus_idle;
      ack_enable      <= '1';
      force_dominant  <= '0';
      force_recessive <= '0';
      wait for c_clk_period * 3;
      rst_n_i         <= '1';
      wait until rising_edge(clk_i);

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
      wait until rising_edge(clk_i);
      bus_i <= c_bus_idle;

    end procedure write_bus;

    -- Fill the mailbox and request the frame, with the first data byte in 63:56

    procedure send_data (
      constant id   : in natural;
      constant dlc  : in natural;
      constant data : in std_logic_vector(63 downto 0)
    ) is
    begin

      write_bus(c_can_id_addr, std_logic_vector(to_unsigned(id, 32)));
      write_bus(c_can_dlc_addr, std_logic_vector(to_unsigned(dlc, 32)));
      write_bus(c_can_data_addr, data(63 downto 32));
      write_bus(c_can_data_hi_addr, data(31 downto 0));
      write_bus(c_can_tx_request_addr, x"00000001");

    end procedure send_data;

    -- The data bytes these tests send: the low 8 * n bits of the payload repeated

    impure function data_for (
      constant dlc     : in natural;
      constant payload : in natural
    ) return std_logic_vector is

      constant c_payload_bits : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(payload, 16));

    begin

      return std_logic_vector(shift_left(unsigned(c_payload_bits & c_payload_bits & c_payload_bits & c_payload_bits),
                                          64 - minimum(dlc, 8) * 8));

    end function data_for;

    procedure write_mailbox (
      constant id      : in natural;
      constant dlc     : in natural;
      constant payload : in natural
    ) is
    begin

      send_data(id, dlc, data_for(dlc, payload));

    end procedure write_mailbox;

    -- One-clock read: the CPU takes the data in the cycle after the strobe

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
      wait until rising_edge(clk_i);
      bus_i   <= c_bus_idle;
      wait until rising_edge(clk_i);
      v_rdata := rdata_o;

    end procedure read_bus;

    -- Expected STATUS: bits 16:8 = TEC, 3 = interrupt, 2 = bus-off, 1 = error passive,
    -- 0 = busy

    procedure check_status (
      constant count   : in natural;
      constant bus_off : in std_logic;
      constant passive : in std_logic;
      constant busy    : in std_logic;
      constant irq     : in std_logic := '0'
    ) is
    begin

      read_bus(c_can_status_addr);
      check_equal(v_rdata, std_logic_vector(to_unsigned(0, 15)) & std_logic_vector(to_unsigned(count, 9)) &
                  "0000" & irq & bus_off & passive & busy, "STATUS");

    end procedure check_status;

    procedure start_rival (
      constant wire : in string
    ) is
    begin

      rival_wire(1 to wire'length) <= wire;
      rival_length                 <= wire'length;
      rival_go                     <= not rival_go;

    end procedure start_rival;

    -- Hold a force signal for one wire bit, counted from a SOF happening now.
    -- The extra clock overlaps the next bit, so that an error flag starting
    -- there does not leave a zero-width recessive gap on the bus.

    procedure force_bit (
      signal force_s : out std_logic;
      constant index : in natural
    ) is
    begin

      wait for c_bit_time * index;
      force_s <= '1';
      wait for c_bit_time + c_clk_period;
      force_s <= '0';

    end procedure force_bit;

    procedure wait_for_sof is
    begin

      wait until can_tx_o = '0' for c_max_frame_time;
      check(can_tx_o = '0', "DUT starts a frame");
      v_sof := now;

    end procedure wait_for_sof;

    -- The DUT acknowledges another node's frame, which looks like a SOF from here

    procedure wait_for_ack is
    begin

      wait until can_tx_o = '0' for c_max_frame_time;
      check(can_tx_o = '0', "DUT acknowledges");
      wait until can_tx_o = '1' for c_bit_time * 2;

    end procedure wait_for_ack;

    procedure wait_for_frame is
    begin

      v_seen := v_seen + 1;

      if (rx_done < v_seen) then
        wait until rx_done >= v_seen for c_max_frame_time * 2;
      end if;

      check(rx_done >= v_seen, "frame finished on the wire");

    end procedure wait_for_frame;

    procedure check_frame_data (
      constant id       : in natural;
      constant dlc      : in natural;
      constant data     : in std_logic_vector(63 downto 0);
      constant from_dut : in boolean := true
    ) is
    begin

      wait_for_frame;
      check(not rx_frame.stuff_error, "no stuff error");
      check_equal(rx_frame.id, std_logic_vector(to_unsigned(id, 11)), "ID");
      check_equal(rx_frame.flags, std_logic_vector'("000"), "RTR, IDE and r0 dominant");
      check_equal(rx_frame.dlc, std_logic_vector(to_unsigned(dlc, 4)), "DLC");
      check_equal(rx_frame.data, data, "data bytes");
      check_equal(rx_frame.crc, rx_frame.crc_expected, "CRC sequence");
      check_equal(rx_frame.crc_delimiter, '1', "CRC delimiter recessive");
      check_equal(rx_frame.ack_slot, '0', "receiver acknowledged");

      -- A transmitter leaves the ACK to its receivers, and the DUT is one of those
      -- for any other node's frame
      if (from_dut) then
        check_equal(rx_frame.wire(rx_frame.wire_length - 12), '1', "DUT leaves the ACK slot recessive");
      else
        check_equal(rx_frame.wire(rx_frame.wire_length - 12), '0', "DUT acknowledges");
      end if;

      check_equal(rx_frame.ack_delimiter, '1', "ACK delimiter recessive");
      check_equal(rx_frame.tail_recessive, 10, "EOF and intermission recessive");

    end procedure check_frame_data;

    procedure check_frame (
      constant id       : in natural;
      constant dlc      : in natural;
      constant payload  : in natural;
      constant from_dut : in boolean := true
    ) is
    begin

      check_frame_data(id, dlc, data_for(dlc, payload), from_dut);

    end procedure check_frame;

    procedure send_and_check (
      constant id      : in natural;
      constant dlc     : in natural;
      constant payload : in natural
    ) is
    begin

      write_mailbox(id, dlc, payload);
      check_frame(id, dlc, payload);
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
      wait until rising_edge(clk_i);

    end procedure check_wire;

    -- Start a mostly dominant frame and stop on one of its dominant bits

    procedure start_dominant_frame is
    begin

      write_mailbox(16#000#, 8, 16#0000#);
      wait_for_sof;
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

    -- Run failed attempts with no ACK until the error counter reaches 128

    procedure become_error_passive is
    begin

      ack_enable <= '0';
      write_mailbox(c_id, c_dlc, c_payload);

      for attempt in 1 to 16 loop

        wait_for_frame;
        check_equal(wire_tail, c_tail_active_flag, "active error flag");
        check_equal(tec, attempt * 8, "error counter");

      end loop;

      check_equal(can_status_o(c_status_passive), '1', "error passive at 128");

    end procedure become_error_passive;

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

          force_dominant <= '1';
          wait for c_bit_time;
          force_dominant <= '0';
          wait for c_bit_time;

        end loop;

        check_equal(tx_falls, 0, "no frame without a mailbox write");
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
        check_wire(c_id, c_dlc, c_payload, c_wire);
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
        wait_for_sof;
        v_edge := now;

        while (can_busy_o = '1') loop

          wait on can_tx_o, can_busy_o;

          if (can_tx_o'event) then
            check_equal((now - v_edge) mod c_bit_time, 0 ns, "TX edge on a bit boundary");
            v_edge := now;
          end if;

        end loop;

        v_end := now;
        wait_for_frame;
        check_equal(v_end - v_sof, c_bit_time * (rx_frame.wire_length - 3), "busy until the end of EOF");
      elsif run("back_to_back_frames_keep_intermission") then
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        wait until can_busy_o = '0' for c_max_frame_time;
        wait until rising_edge(clk_i);
        write_mailbox(16#321#, 2, 16#5AA5#);
        v_edge := v_sof;
        wait_for_sof;
        check_equal(v_sof - v_edge, c_bit_time * c_wire'length, "second SOF right after the intermission");
        check_frame(c_id, c_dlc, c_payload);
        check_frame(16#321#, 2, 16#5AA5#);
      elsif run("write_blocked_while_gate_low") then
        bus_ok_i <= '0';
        write_mailbox(c_id, c_dlc, c_payload);
        bus_ok_i <= '1';
        wait for c_max_frame_time;
        check_equal(rx_starts, 0, "no frame from a blocked write");
        check(can_busy_o = '0', "idle after a blocked write");

        -- The mailbox stayed empty, so the next write goes through intact
        wait until rising_edge(clk_i);
        send_and_check(16#321#, 2, 16#5AA5#);
      elsif run("write_to_any_other_address_is_ignored") then
        wait for c_bit_time * 12;

        -- Every address one bit away from TX_REQUEST
        for addr_bit in 0 to 31 loop

          v_addr           := c_can_tx_request_addr;
          v_addr(addr_bit) := not v_addr(addr_bit);
          write_bus(v_addr, x"00000001");
          wait until rising_edge(clk_i);
          check(can_busy_o = '0', "write to another address ignored");

        end loop;

        write_bus(c_uart_tx_data_addr, x"00000001");
        wait until rising_edge(clk_i);
        check(can_busy_o = '0', "write to the UART ignored");
        check_equal(tx_falls, 0, "no frame from another address");

        -- The mailbox stayed empty, so the next write goes through intact
        send_and_check(16#321#, 2, 16#5AA5#);
      elsif run("status_register_follows_the_frame_and_the_error_counter") then
        check_status(0, '0', '0', '0');

        ack_enable <= '0';
        write_mailbox(c_id, c_dlc, c_payload);
        wait until rising_edge(clk_i);
        check_status(0, '0', '0', '1');

        for attempt in 1 to 16 loop

          wait_for_frame;
          wait until rising_edge(clk_i);
          check_status(attempt * 8, '0', std_logic'val(std_logic'pos('0') + attempt / 16), '1', '1');

        end loop;

        -- The frame gets through, which also takes 1 off the counter
        ack_enable <= '1';
        wait until can_busy_o = '0' for c_max_frame_time * 2;
        wait until rising_edge(clk_i);
        check_status(127, '0', '0', '0', '1');
      elsif run("status_register_reports_bus_off") then
        force_recessive <= '1';
        write_mailbox(c_id, c_dlc, c_payload);
        wait until tx_falls = 32 for c_max_frame_time * 32;
        wait for c_bit_time * 8;
        wait until rising_edge(clk_i);
        check_status(256, '1', '1', '0', '1');
      elsif run("reads_answer_only_at_the_status_address") then
        wait for c_bit_time * 12;
        ack_enable <= '0';
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_frame;
        wait until rising_edge(clk_i);

        -- STATUS is not zero now, so a stray decode would show. Every address
        -- one bit away reads zero, and the data is only there for one cycle.
        for addr_bit in 0 to 31 loop

          -- Bits 2 and 3 select the DATA and DLC registers
          next when addr_bit = 2 or addr_bit = 3;
          v_addr           := c_can_status_addr;
          v_addr(addr_bit) := not v_addr(addr_bit);
          read_bus(v_addr);
          check_equal(v_rdata, std_logic_vector(to_unsigned(0, 32)), "another address reads zero");

        end loop;

        read_bus(c_can_status_addr);
        check(v_rdata /= x"00000000", "STATUS has something to report");
        wait until rising_edge(clk_i);
        check_equal(rdata_o, std_logic_vector(to_unsigned(0, 32)), "read data lasts one cycle");

        -- The safety gate blocks reads as well as writes
        bus_ok_i <= '0';
        read_bus(c_can_status_addr);
        bus_ok_i <= '1';
        check_equal(v_rdata, std_logic_vector(to_unsigned(0, 32)), "gate low reads zero");
      elsif run("write_to_status_only_clears_the_interrupt") then
        wait for c_bit_time * 12;
        write_bus(c_can_status_addr, x"00000001");
        wait until rising_edge(clk_i);
        check(can_busy_o = '0', "a STATUS write starts nothing");
        check_equal(tx_falls, 0, "no frame");
      elsif run("failed_frame_raises_the_interrupt_until_status_is_written") then
        check_equal(can_irq_o, '0', "no interrupt after reset");
        ack_enable <= '0';
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        wait for c_bit_time * c_ack_slot;
        check_equal(can_irq_o, '0', "no interrupt before the error");
        wait for c_bit_time * 2;
        check_equal(can_irq_o, '1', "interrupt with the error flag");

        -- Reading must not clear it: software polling STATUS would lose it
        wait until rising_edge(clk_i);
        read_bus(c_can_status_addr);
        wait until rising_edge(clk_i);
        check_equal(can_irq_o, '1', "a read does not clear the interrupt");

        -- Nor does a partial store, or a write elsewhere
        write_bus(c_can_status_addr, x"00000001", "0001");
        write_bus(c_can_data_addr, x"00000001");
        write_bus(x"C000030C", x"00000001");
        wait until rising_edge(clk_i);
        check_equal(can_irq_o, '1', "only a word store to STATUS clears it");

        write_bus(c_can_status_addr, x"00000000");
        wait until rising_edge(clk_i);
        check_equal(can_irq_o, '0', "a write to STATUS clears it");

        -- Every failure raises it again
        wait_for_frame;
        wait_for_sof;
        wait for c_bit_time * (c_ack_slot + 2);
        check_equal(can_irq_o, '1', "the next failure raises it again");
      elsif run("failure_beats_a_status_write_on_the_same_clock") then
        ack_enable <= '0';
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;

        -- A store held across the error lands on the clock it starts
        bus_i <=
        (
          addr  => c_can_status_addr,
          data  => x"00000000",
          we    => '1',
          valid => '1',
          sel   => "1111"
        );
        wait until can_irq_o = '1' for c_max_frame_time;
        check_equal(can_irq_o, '1', "the failure is not lost");
        bus_i <= c_bus_idle;
      elsif run("lost_arbitration_raises_no_interrupt") then
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        start_rival(c_rival_win);
        check_frame(16#122#, c_dlc, c_payload, false);
        check_frame(c_id, c_dlc, c_payload);
        check_equal(can_irq_o, '0', "losing arbitration is not an error");
      elsif run("safety_gate_blocks_clearing_the_interrupt") then
        ack_enable <= '0';
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_frame;
        check_equal(can_irq_o, '1', "interrupt raised");
        wait until rising_edge(clk_i);
        bus_ok_i   <= '0';
        write_bus(c_can_status_addr, x"00000000");
        bus_ok_i   <= '1';
        wait until rising_edge(clk_i);
        check_equal(can_irq_o, '1', "the gate blocks the write");
      elsif run("all_8_data_bytes_are_independent") then
        send_data(c_id, 8, x"1122334455667788");
        check_frame_data(c_id, 8, x"1122334455667788");
        check_equal(to_string(rx_frame.wire(0 to rx_frame.wire_length - 1)), c_wire_8_bytes, "wire bits");
      elsif run("registers_read_back_what_was_written") then
        write_bus(c_can_id_addr, x"FFFFFFFF");
        write_bus(c_can_dlc_addr, x"FFFFFFFF");
        write_bus(c_can_data_addr, x"11223344");
        write_bus(c_can_data_hi_addr, x"55667788");

        read_bus(c_can_id_addr);
        check_equal(v_rdata, std_logic_vector'(x"000007FF"), "ID is 11 bits");
        read_bus(c_can_dlc_addr);
        check_equal(v_rdata, std_logic_vector'(x"0000000F"), "DLC is 4 bits");
        read_bus(c_can_data_addr);
        check_equal(v_rdata, std_logic_vector'(x"11223344"), "DATA");
        read_bus(c_can_data_hi_addr);
        check_equal(v_rdata, std_logic_vector'(x"55667788"), "DATA_HI");
        read_bus(c_can_tx_request_addr);
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "TX_REQUEST is write only");
      elsif run("filling_the_mailbox_does_not_start_a_frame") then
        wait for c_bit_time * 12;
        write_bus(c_can_id_addr, x"00000123");
        write_bus(c_can_dlc_addr, x"00000002");
        write_bus(c_can_data_addr, x"A55A0000");
        write_bus(c_can_data_hi_addr, x"00000000");
        wait until can_tx_o = '0' for c_max_frame_time;
        check(can_tx_o = '1', "no frame before TX_REQUEST");
        check(can_busy_o = '0', "idle before TX_REQUEST");

        write_bus(c_can_tx_request_addr, x"00000000");
        check_frame(c_id, c_dlc, c_payload);
      elsif run("mailbox_is_locked_until_the_frame_is_sent") then
        ack_enable <= '0';
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_frame;

        -- Between attempts: nothing may change what gets sent again
        write_bus(c_can_id_addr, x"00000321");
        write_bus(c_can_dlc_addr, x"00000008");
        write_bus(c_can_data_addr, x"FFFFFFFF");
        write_bus(c_can_data_hi_addr, x"FFFFFFFF");
        read_bus(c_can_id_addr);
        check_equal(v_rdata, std_logic_vector(to_unsigned(c_id, 32)), "ID unchanged");

        ack_enable <= '1';
        check_frame(c_id, c_dlc, c_payload);
      elsif run("mailbox_keeps_its_contents_to_send_again") then
        send_and_check(c_id, c_dlc, c_payload);
        write_bus(c_can_tx_request_addr, x"00000001");
        check_frame(c_id, c_dlc, c_payload);
      elsif run("partial_stores_do_not_reach_the_registers") then
        wait for c_bit_time * 12;

        -- Every combination of byte enables except a full word
        for pattern in 0 to 14 loop

          v_sel := std_logic_vector(to_unsigned(pattern, 4));
          write_bus(c_can_id_addr, x"00000123", v_sel);
          write_bus(c_can_tx_request_addr, x"00000001", v_sel);
          wait until rising_edge(clk_i);
          check(can_busy_o = '0', "partial store does not start a frame");
          read_bus(c_can_id_addr);
          check_equal(v_rdata, std_logic_vector'(x"00000000"), "partial store leaves ID alone");

        end loop;

        send_and_check(c_id, c_dlc, c_payload);
      elsif run("gate_drop_clears_the_mailbox") then
        write_bus(c_can_id_addr, x"00000123");
        bus_ok_i <= '0';
        wait until rising_edge(clk_i);
        bus_ok_i <= '1';
        read_bus(c_can_id_addr);
        check_equal(v_rdata, std_logic_vector'(x"00000000"), "ID cleared");
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
          write_mailbox(c_id, 8, c_payload);
          wait_for_sof;
          wait for c_bit_time * step * step;
          wait until rising_edge(clk_i);
          write_mailbox(16#321#, 2, 16#5AA5#);
          check_frame(c_id, 8, c_payload);
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
      elsif run("waits_for_11_recessive_bits_after_reset") then
        v_edge := now;
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        check(v_sof - v_edge >= c_bit_time * 11 - c_clk_period * 4, "bus integrated before the first frame");
        check_frame(c_id, c_dlc, c_payload);
      elsif run("defers_to_a_frame_already_on_the_bus") then
        wait for c_bit_time * 12;

        -- Whatever the rival's phase, the DUT lines up with its edges
        for phase in 1 to c_clks_per_bit loop

          wait for c_clk_period * phase;
          start_rival(c_rival_win);
          v_edge := now;
          wait for c_bit_time * 10;
          wait until rising_edge(clk_i);
          write_mailbox(c_id, c_dlc, c_payload);
          wait_for_ack;
          wait_for_sof;
          check(
                abs((v_sof - v_edge) - c_bit_time * c_rival_win'length) <= c_clk_period * 3,
                "SOF right after the rival's intermission"
              );
          check_frame(16#122#, c_dlc, c_payload, false);
          check_frame(c_id, c_dlc, c_payload);
          wait for c_bit_time * 12;

        end loop;

      elsif run("stuck_dominant_bus_blocks_transmission") then
        force_dominant <= '1';
        write_mailbox(c_id, c_dlc, c_payload);
        wait until can_tx_o = '0' for c_max_frame_time;
        check(can_tx_o = '1', "no frame on a dominant bus");
        check(can_busy_o = '1', "frame stays pending");
        wait_for_frame;

        force_dominant <= '0';
        v_edge         := now;
        wait_for_sof;
        check(v_sof - v_edge >= c_bit_time * 11 - c_clk_period * 4, "11 recessive bits after the bus clears");
        check_frame(c_id, c_dlc, c_payload);
      elsif run("lost_arbitration_stops_and_retries") then
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        start_rival(c_rival_win);
        v_edge := now;

        -- The rival's frame is undisturbed
        check_frame(16#122#, c_dlc, c_payload, false);
        check_equal(to_string(rx_frame.wire(0 to 11)), c_wire(1 to 12), "DUT sends until it loses");
        check_equal(and rx_frame.wire(12 to rx_frame.wire_length - 13), '1', "DUT recessive after losing");
        check_equal(and rx_frame.wire(rx_frame.wire_length - 11 to rx_frame.wire_length - 1), '1', "and after the ACK");
        check_equal(tec, 0, "losing arbitration is not an error");

        -- The DUT tries again as soon as the bus is idle
        wait_for_sof;
        check(
              abs((v_sof - v_edge) - c_bit_time * c_rival_win'length) <= c_clk_period * 3,
              "retry right after the rival's intermission"
            );
        check_frame(c_id, c_dlc, c_payload);
        check(can_busy_o = '0', "frame sent");
      elsif run("won_arbitration_keeps_sending") then
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        start_rival(c_rival_lose);
        check_frame(c_id, c_dlc, c_payload);
        check_equal(to_string(rx_frame.wire(0 to rx_frame.wire_length - 1)), c_wire, "wire bits");
        check_equal(tec, 0, "no error");
      elsif run("joins_a_simultaneous_start_at_any_phase") then
        wait for c_bit_time * 12;

        -- Move the start around the DUT's bit timer, so that it sometimes sees
        -- the rival's SOF edge first and has to join it
        for phase in 1 to c_clks_per_bit loop

          wait for c_clk_period * phase;
          wait until rising_edge(clk_i);
          write_mailbox(c_id, c_dlc, c_payload);
          start_rival(c_rival_lose);
          check_frame(c_id, c_dlc, c_payload);
          check_equal(tec, 0, "no error");
          wait for c_bit_time * 12;

        end loop;

      elsif run("joins_a_sof_in_the_third_intermission_bit") then
        wait for c_bit_time * 12;

        -- The rival's first frame without its last bit, then a second frame
        start_rival(c_rival_win(1 to c_rival_win'length - 1) & c_rival_lose);
        wait for c_bit_time * 10;
        wait until rising_edge(clk_i);
        write_mailbox(c_id, c_dlc, c_payload);

        wait_for_frame;
        check_equal(rx_frame.id, std_logic_vector(to_unsigned(16#122#, 11)), "first frame ID");
        check_frame(c_id, c_dlc, c_payload);
        check_equal(rx_starts, 2, "the DUT took part in the frame that started in intermission");
      elsif run("missing_ack_sends_error_flag_and_retries") then
        ack_enable <= '0';
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        wait_for_frame;
        check_equal(rx_frame.ack_slot, '1', "nobody acknowledged");
        check_equal(wire_tail, c_tail_active_flag, "6 dominant bits from the bit after the ACK slot");
        check_equal(tec, 8, "an ACK error adds 8");
        check(can_busy_o = '1', "frame still pending");

        v_edge     := v_sof;
        ack_enable <= '1';
        wait_for_sof;
        check_equal(v_sof - v_edge, c_bit_time * c_retry_bits, "retry after the error delimiter and intermission");
        check_frame(c_id, c_dlc, c_payload);
        check_equal(tec, 7, "a good frame takes away 1");
        check(can_busy_o = '0', "frame sent");
      elsif run("dominant_on_recessive_bit_is_a_bit_error") then
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        force_bit(force_dominant, 22);
        wait_for_frame;
        check_equal(to_string(rx_frame.wire(23 to rx_frame.wire_length - 1)), "0000", "flag from the next bit");
        wait for c_bit_time * 20;
        check_equal(tec, 8, "a bit error adds 8");
        check_frame(c_id, c_dlc, c_payload);
        check_equal(tec, 7, "a good frame takes away 1");
      elsif run("recessive_on_dominant_bit_is_a_bit_error") then
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        force_bit(force_recessive, 4);
        wait_for_frame;
        check_equal(to_string(rx_frame.wire(5 to rx_frame.wire_length - 1)), "00000", "flag from the next bit");
        wait for c_bit_time * 20;
        check_equal(tec, 8, "a bit error adds 8");
        check_frame(c_id, c_dlc, c_payload);
      elsif run("dominant_on_id_bit_loses_arbitration_without_a_flag") then
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        v_falls := tx_falls;
        v_edge  := v_sof;
        force_bit(force_dominant, 3);

        -- It lost to nobody, so the bus goes quiet and it has become a receiver of
        -- a frame that has stopped. Six recessive bits are a stuff error, and four
        -- dominant bits and those six make ten.
        wait_for_sof;
        check_equal(v_sof - v_edge, c_bit_time * 10, "error flag, as a receiver");
        check_equal(tx_falls, v_falls + 1, "nothing before the flag");
        check_equal(tec, 0, "no transmit error");

        -- Flag, delimiter and intermission
        wait until can_tx_o = '1' for c_bit_time * 7;
        wait_for_sof;
        check_equal(v_sof - v_edge, c_bit_time * (10 + 6 + 11), "then the retry");
        wait_for_frame;
        wait_for_frame;
        check_frame(c_id, c_dlc, c_payload);
      elsif run("dominant_stuff_bit_in_arbitration_is_not_counted") then
        -- ID 0: the stuff bit at position 5 is recessive and comes before RTR
        write_mailbox(16#000#, 8, 16#0000#);
        wait_for_sof;
        force_bit(force_dominant, 5);
        wait for c_bit_time;
        check(can_tx_o = '0', "an error flag, not lost arbitration");
        wait_for_frame;
        wait for c_bit_time * 10;
        check_equal(tec, 0, "exception 2 in ISO 11898-1");
        check_frame(16#000#, 8, 16#0000#);
        check_equal(tec, 0, "still no error");
      elsif run("dominant_on_control_bit_is_a_bit_error") then
        -- Position 18 is a recessive DLC bit: arbitration ended with RTR
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        force_bit(force_dominant, 18);
        wait for c_bit_time;
        check(can_tx_o = '0', "an error flag, not lost arbitration");
        wait_for_frame;
        wait for c_bit_time * 6;
        check_equal(tec, 8, "a bit error adds 8");
        check_frame(c_id, c_dlc, c_payload);
      elsif run("dominant_on_last_eof_bit_fails_the_frame") then
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        force_bit(force_dominant, c_last_eof);
        wait until can_busy_o = '0' for c_max_frame_time * 2;
        check_equal(rx_starts, 3, "good frame, error flag read as a SOF, then the retry");
        check_equal(tec, 7, "failed once, then sent");
      elsif run("dominant_in_intermission_does_not_repeat_the_frame") then
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        force_bit(force_dominant, c_ifs_1);
        wait_for_frame;
        check_no_more_traffic("frame was already sent");
        check_equal(tec, 0, "no error");
      elsif run("error_passive_sends_recessive_flags_and_suspends") then
        become_error_passive;

        wait_for_sof;
        v_edge := v_sof;
        wait_for_frame;
        check_equal(wire_tail, "1111111111111", "error passive flag is recessive");
        check_equal(tec, 128, "a lone node does not count a missing ACK while passive");
        wait_for_sof;
        check_equal(v_sof - v_edge, c_bit_time * c_passive_retry_bits, "retry after the suspend time");

        ack_enable <= '1';
        check_frame(c_id, c_dlc, c_payload);
        check_equal(tec, 127, "a good frame takes away 1");
        check_equal(can_status_o(c_status_passive), '0', "error active again");
      elsif run("error_passive_flag_answered_on_the_bus_is_counted") then
        become_error_passive;

        wait_for_sof;
        wait for c_bit_time * (c_ack_slot + 3);
        force_dominant <= '1';
        wait for c_bit_time;
        force_dominant <= '0';
        wait for c_bit_time * 6;
        check_equal(tec, 136, "dominant bit during the passive flag");
      elsif run("error_passive_suspends_after_a_good_frame") then
        become_error_passive;

        ack_enable <= '1';
        wait_for_sof;
        v_edge     := v_sof;
        wait until can_busy_o = '0' for c_max_frame_time;
        check_equal(tec, 127, "frame sent");
        wait until rising_edge(clk_i);
        write_mailbox(16#321#, 2, 16#5AA5#);
        wait_for_sof;
        check_equal(v_sof - v_edge, c_bit_time * (c_wire'length + 8), "SOF after intermission and suspend time");
      elsif run("suspend_time_gives_way_to_another_node") then
        become_error_passive;

        ack_enable <= '1';
        wait_for_sof;
        wait until can_busy_o = '0' for c_max_frame_time;
        wait until rising_edge(clk_i);
        write_mailbox(16#321#, 2, 16#5AA5#);

        -- A rival starts after the intermission, during the suspend time
        wait for c_bit_time * 7;
        check(can_tx_o = '1', "still suspended");
        start_rival(c_rival_win);
        v_edge := now;
        wait for c_bit_time * 2;
        wait_for_ack;
        wait_for_sof;
        check(
              abs((v_sof - v_edge) - c_bit_time * c_rival_win'length) <= c_clk_period * 3,
              "only the rival's intermission, with no suspend time left"
            );
      elsif run("bus_off_after_32_errors_until_reset") then
        -- A broken RX path: every SOF reads back recessive
        force_recessive <= '1';
        write_mailbox(c_id, c_dlc, c_payload);

        for attempt in 1 to 32 loop

          wait until tx_falls = attempt for c_max_frame_time;
          check_equal(tx_falls, attempt, "attempt");
          check_equal(tec, (attempt - 1) * 8, "error counter");
          check_equal(can_status_o(c_status_passive) = '1', attempt > 16, "error state");
          check_equal(can_status_o(c_status_bus_off), '0', "not bus-off yet");

        end loop;

        wait for c_bit_time * 8;
        check_equal(tec, 256, "error counter");
        check_equal(can_status_o(c_status_bus_off), '1', "bus-off");
        check(can_tx_o = '1', "bus-off is recessive");
        check(can_busy_o = '0', "pending frame dropped");

        -- A write does not get through, and neither does a healthy bus help
        force_recessive <= '0';
        wait until rising_edge(clk_i);
        write_mailbox(c_id, c_dlc, c_payload);
        check(can_busy_o = '0', "writes are ignored while bus-off");
        wait until can_tx_o = '0' for c_max_frame_time * 2;
        check(can_tx_o = '1', "no automatic recovery");

        reset_dut;
        check_equal(can_status_o, std_logic_vector(to_unsigned(0, 11)), "reset clears the fault state");
        v_seen := rx_done;
        send_and_check(c_id, c_dlc, c_payload);
      elsif run("gate_drop_during_error_flag_forces_recessive") then
        ack_enable <= '0';
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        wait for c_bit_time * (c_ack_slot + 3);
        check(can_tx_o = '0', "error flag in progress");

        bus_ok_i <= '0';
        wait for 1 ns;
        check(can_tx_o = '1', "recessive without waiting for a clock");
        wait until rising_edge(clk_i);
        wait until rising_edge(clk_i);
        bus_ok_i <= '1';
        check_no_more_traffic("no retry after the gate returns");
        check_equal(tec, 0, "the flag never finished");
      elsif run("gate_drop_while_waiting_to_retry_drops_the_frame") then
        ack_enable <= '0';
        write_mailbox(c_id, c_dlc, c_payload);
        wait_for_sof;
        wait_for_frame;
        check_equal(tec, 8, "failed once");
        check(can_busy_o = '1', "waiting to retry");

        wait until rising_edge(clk_i);
        bus_ok_i <= '0';
        wait until rising_edge(clk_i);
        bus_ok_i <= '1';
        check_no_more_traffic("frame dropped with the gate");
        check_equal(tec, 8, "the gate does not clear the error counter");
      end if;

    end loop;

    test_runner_cleanup(runner);

  end process p_stim;

end architecture tb;
