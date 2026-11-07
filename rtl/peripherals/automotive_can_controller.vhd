-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Fault-Hardened CAN 2.0B Controller
-- Module Name:  automotive_can_controller - behavioral
-- Description:  Transmits CAN base-format data frames with bit-stuffing and
--               CRC-15, and only while the lockstep comparator validates the
--               bus. An internal mailbox buffers one outgoing frame.
--
--               Follows the bus on can_rx_i: waits for it to go idle,
--               arbitrates, monitors its own bits and checks for an ACK. A
--               failed frame stays in the mailbox and is sent again, with
--               ISO 11898-1 error counting to keep a faulty node off the bus.
--
--               Transmit only: it does not receive or acknowledge other nodes'
--               frames, or send overload frames. Bus-off is latched until reset.
--
-- Traces to:    TSR_CAN_001
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity automotive_can_controller is
  generic (
    -- System clocks per CAN bit: 100 gives 500 kbit/s from a 50 MHz clock
    g_clks_per_bit : positive range 8 to 65535 := 100
  );
  port (
    clk_i   : in    std_logic;
    rst_n_i : in    std_logic;

    -- Internal bus from lockstep comparator (gated by safety)
    bus_i    : in    t_rv_bus;
    bus_ok_i : in    std_logic; -- Hardware transaction validation gate

    -- Register read data: valid the cycle after the strobe, otherwise zero
    rdata_o : out   std_logic_vector(c_data_width - 1 downto 0);

    -- External CAN transceiver interface
    can_tx_o : out   std_logic;
    can_rx_i : in    std_logic;

    -- Diagnostic
    can_busy_o   : out   std_logic;
    can_status_o : out   std_logic_vector(10 downto 0) -- 10: bus-off, 9: error passive, 8:0: TEC
  );
end entity automotive_can_controller;

architecture rtl of automotive_can_controller is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_CAN_001";

  -- Frame field lengths in bits
  constant c_id_bits       : unsigned(7 downto 0) := to_unsigned(12, 8); -- ID + RTR
  constant c_ctrl_bits     : unsigned(7 downto 0) := to_unsigned(6, 8);  -- IDE + r0 + DLC
  constant c_max_data_bits : unsigned(7 downto 0) := to_unsigned(64, 8);
  constant c_crc_bits      : unsigned(7 downto 0) := to_unsigned(15, 8);
  constant c_ack_bits      : unsigned(7 downto 0) := to_unsigned(3, 8);  -- CRC delim, ACK slot, ACK delim
  constant c_eof_bits      : unsigned(7 downto 0) := to_unsigned(8, 8);  -- 7 bits, then the tick ending them
  constant c_flag_bits     : unsigned(7 downto 0) := to_unsigned(6, 8);

  -- RTR, IDE and r0 are dominant: a data frame in base format
  constant c_dominant : std_logic_vector(0 downto 0) := "0";
  constant c_ctrl_hdr : std_logic_vector(1 downto 0) := "00";

  -- Bit stuffing: a complementary bit follows this many identical bits
  constant c_stuff_run : unsigned(2 downto 0) := to_unsigned(5, 3);

  -- CRC-15 generator polynomial
  constant c_crc_poly : unsigned(14 downto 0) := to_unsigned(16#4599#, 15);

  -- Bit timer values: sample 75% into the bit, and allow for an edge reaching
  -- this logic 3 clocks late through the synchroniser. The transceiver and
  -- bus loop delay must stay below the sample point less those 3 clocks.
  constant c_sample_cnt : natural := g_clks_per_bit - (3 * g_clks_per_bit) / 4;
  constant c_sync_cnt   : natural := g_clks_per_bit - 3;

  -- Recessive bits that end a transfer: ACK delimiter, EOF and intermission,
  -- or error delimiter and intermission. An error passive transmitter then
  -- waits out the suspend time as well.
  constant c_idle_bits    : natural := 11;
  constant c_suspend_bits : natural := 8;

  -- ISO 11898-1 transmit error counting
  constant c_tec_step    : unsigned(8 downto 0) := to_unsigned(8, 9);
  constant c_tec_passive : unsigned(8 downto 0) := to_unsigned(128, 9);
  constant c_tec_bus_off : unsigned(8 downto 0) := to_unsigned(256, 9);

  -- CAN frame state machine: the state names the field of the next bit to send

  type t_can_state is (
    idle,
    tx_id,
    tx_ctrl,
    tx_data,
    tx_crc,
    tx_ack,
    tx_eof,
    tx_error_flag
  );

  signal r_state : t_can_state;

  -- Mailbox: holds one outgoing frame
  signal r_mailbox_id   : std_logic_vector(10 downto 0);
  signal r_mailbox_dlc  : unsigned(3 downto 0);
  signal r_mailbox_data : std_logic_vector(63 downto 0);
  signal r_mailbox_full : std_logic;

  -- RX synchroniser
  signal r_rx_meta : std_logic;
  signal r_rx      : std_logic;
  signal r_rx_prev : std_logic;
  signal w_rx_fall : std_logic;

  -- Bit timing
  signal r_bit_cnt     : integer range 0 to g_clks_per_bit - 1;
  signal w_bit_tick    : std_logic;
  signal w_sample_tick : std_logic;
  signal w_hard_sync   : std_logic;

  -- Bus state
  signal r_recessive_run : integer range 0 to c_idle_bits + c_suspend_bits;
  signal r_bus_idle      : std_logic;
  signal r_suspend       : std_logic;
  signal w_idle_limit    : integer range 0 to c_idle_bits + c_suspend_bits;
  signal w_ifs_sof       : std_logic;
  signal w_tx_start      : std_logic;

  -- Bit-stuffing counter and the level on the TX pin
  signal r_stuff_count  : unsigned(2 downto 0);
  signal r_tx_pin       : std_logic;
  signal w_stuff_insert : std_logic;

  -- TX shift register: left-aligned, the next bit to send is in bit 63
  signal r_tx_shift     : std_logic_vector(63 downto 0);
  signal r_tx_bits_left : unsigned(7 downto 0);
  signal w_next_bit     : std_logic;
  signal w_send_bit     : std_logic;
  signal w_frame_done   : std_logic;
  signal w_flag_done    : std_logic;

  -- Fields covered by the CRC and by bit stuffing
  signal w_crc_field     : std_logic;
  signal w_stuffed_field : std_logic;

  -- CRC-15 register
  signal r_crc_reg : unsigned(14 downto 0);

  -- Bit monitor: the role of the bit on the wire, and what sampling it found
  signal r_cur_arb         : std_logic;
  signal r_cur_stuff       : std_logic;
  signal r_cur_ack         : std_logic;
  signal r_arb_lost        : std_logic;
  signal r_bit_error       : std_logic;
  signal r_arb_stuff_error : std_logic;
  signal r_ack_seen        : std_logic;
  signal w_frame_active    : std_logic;
  signal w_ack_missing     : std_logic;
  signal w_arb_fail        : std_logic;
  signal w_tx_fail         : std_logic;

  -- Fault confinement
  signal r_tec           : unsigned(8 downto 0);
  signal r_bus_off       : std_logic;
  signal r_ack_error     : std_logic;
  signal r_uncounted     : std_logic;
  signal r_flag_dominant : std_logic;
  signal w_error_passive : std_logic;
  signal w_count_error   : std_logic;
  signal w_flag_level    : std_logic;

  -- Reset, a dropped safety gate or bus-off clears the whole TX path at once
  signal w_tx_clear : std_logic;

  -- Register reads
  signal w_busy  : std_logic;
  signal r_rdata : std_logic_vector(c_data_width - 1 downto 0);

  -- Place a field at the top of the shift register

  function left_align (
    field : std_logic_vector
  ) return std_logic_vector is

    variable v_result : std_logic_vector(63 downto 0);

  begin

    v_result                              := (others => '0');
    v_result(63 downto 64 - field'length) := field;

    return v_result;

  end function left_align;

  -- Data field length in bits: DLC values above 8 still carry 8 bytes

  function data_bits (
    dlc : unsigned(3 downto 0)
  ) return unsigned is
  begin

    if (dlc > 8) then
      return c_max_data_bits;
    end if;

    return resize(dlc, 5) & "000";

  end function data_bits;

begin

  w_tx_clear <= '1' when (rst_n_i = '0' or bus_ok_i = '0' or r_bus_off = '1') else
                '0';

  -- ========================================================================
  -- 1. MAILBOX LOAD: Accept data from internal bus when safety gate is clear
  -- ========================================================================
  -- The bus is shared with the other peripherals, so only a write to exactly
  -- this address counts. The mailbox stays full until the frame has been sent
  -- without error, so a failed frame can be sent again and a write cannot
  -- overwrite it.
  -- ========================================================================
  p_mailbox : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (w_tx_clear = '1') then
        r_mailbox_id   <= (others => '0');
        r_mailbox_dlc  <= (others => '0');
        r_mailbox_data <= (others => '0');
        r_mailbox_full <= '0';
      elsif (w_frame_done = '1') then
        r_mailbox_full <= '0';
      elsif (bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '1' and
             bus_i.addr = c_can_mailbox_addr and r_mailbox_full = '0') then
        -- Load frame: upper 11 bits = ID, next 4 = DLC, rest = data
        r_mailbox_id   <= bus_i.data(31 downto 21);
        r_mailbox_dlc  <= unsigned(bus_i.data(20 downto 17));
        r_mailbox_data <= bus_i.data(15 downto 0) & bus_i.data(15 downto 0) &
                          bus_i.data(15 downto 0) & bus_i.data(15 downto 0);
        r_mailbox_full <= '1';
      end if;
    end if;

  end process p_mailbox;

  -- ========================================================================
  -- 2. RX SYNCHRONISER (Rule CD-02): can_rx_i is asynchronous to clk_i
  -- ========================================================================
  p_rx_sync : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_rx_meta <= '1';
        r_rx      <= '1';
        r_rx_prev <= '1';
      else
        r_rx_meta <= can_rx_i;
        r_rx      <= r_rx_meta;
        r_rx_prev <= r_rx;
      end if;
    end if;

  end process p_rx_sync;

  w_rx_fall <= '1' when (r_rx_prev = '1' and r_rx = '0') else
               '0';

  -- ========================================================================
  -- 3. BIT TIMING: One tick per CAN bit, one sample per CAN bit
  -- ========================================================================
  -- Bus edges re-phase the timer while listening. A node sending a frame has
  -- hard-synchronised already and keeps its own timing.
  -- ========================================================================
  w_hard_sync <= '1' when (w_rx_fall = '1' and r_state = idle) else
                 '0';

  p_bit_timer : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_bit_cnt <= 0;
      elsif (w_hard_sync = '1') then
        r_bit_cnt <= c_sync_cnt;
      elsif (r_bit_cnt = 0) then
        r_bit_cnt <= g_clks_per_bit - 1;
      else
        r_bit_cnt <= r_bit_cnt - 1;
      end if;
    end if;

  end process p_bit_timer;

  w_bit_tick <= '1' when (r_bit_cnt = 0) else
                '0';

  w_sample_tick <= '1' when (r_bit_cnt = c_sample_cnt) else
                   '0';

  -- ========================================================================
  -- 4. BUS MONITOR: Decide when a frame may start
  -- ========================================================================
  -- Every transfer ends with 11 recessive bits, so counting them also covers
  -- the intermission. After sending while error passive, a node waits out the
  -- suspend time too, unless another node starts first.
  -- ========================================================================
  w_idle_limit <= c_idle_bits + c_suspend_bits when (r_suspend = '1') else
                  c_idle_bits;

  p_bus_monitor : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_recessive_run <= 0;
        r_bus_idle      <= '0';
        r_suspend       <= '0';
      else
        if (w_tx_start = '1' or w_rx_fall = '1') then
          r_bus_idle <= '0';
        end if;

        if (w_sample_tick = '1') then
          if (r_rx = '0') then
            r_recessive_run <= 0;
            r_bus_idle      <= '0';

            if (r_recessive_run >= c_idle_bits) then
              r_suspend <= '0';
            end if;
          else
            if (r_recessive_run < c_idle_bits + c_suspend_bits) then
              r_recessive_run <= r_recessive_run + 1;
            end if;

            if (r_recessive_run + 1 >= w_idle_limit) then
              r_bus_idle <= '1';
              r_suspend  <= '0';
            end if;
          end if;
        end if;

        -- The error delimiter is counted from the end of the error flag
        if (w_flag_done = '1') then
          r_recessive_run <= 0;
        end if;

        if ((w_frame_done = '1' or w_flag_done = '1') and w_error_passive = '1') then
          r_suspend <= '1';
        end if;
      end if;
    end if;

  end process p_bus_monitor;

  -- A dominant third intermission bit is a SOF from another node
  w_ifs_sof <= '1' when (w_sample_tick = '1' and r_rx = '0' and r_suspend = '0' and
                          r_recessive_run = c_idle_bits - 1) else
               '0';

  -- A pending frame starts on a bit boundary once the bus is idle, or joins a
  -- SOF from another node so that it takes part in the arbitration
  w_tx_start <= '1' when (r_state = idle and r_mailbox_full = '1' and
                           (w_ifs_sof = '1' or (r_bus_idle = '1' and (w_bit_tick = '1' or w_rx_fall = '1')))) else
                '0';

  -- ========================================================================
  -- 5. CAN TX STATE MACHINE
  -- ========================================================================
  p_tx_fsm : process (clk_i) is

    variable v_data_bits : unsigned(7 downto 0);

  begin

    if rising_edge(clk_i) then
      if (w_tx_clear = '1') then
        r_state        <= idle;
        r_tx_shift     <= (others => '0');
        r_tx_bits_left <= (others => '0');
      elsif (r_state = idle) then
        if (w_tx_start = '1') then
          -- p_stuffing sends the dominant SOF, so the ID is next
          r_state        <= tx_id;
          r_tx_shift     <= left_align(r_mailbox_id & c_dominant);
          r_tx_bits_left <= c_id_bits;
        end if;
      elsif (w_arb_fail = '1') then
        -- Stop driving: the frame stays in the mailbox for the next idle bus
        r_state <= idle;
      elsif (w_tx_fail = '1') then
        r_state        <= tx_error_flag;
        r_tx_bits_left <= c_flag_bits;
      elsif (w_send_bit = '1') then
        r_tx_shift     <= r_tx_shift(62 downto 0) & '0';
        r_tx_bits_left <= r_tx_bits_left - 1;

        if (r_tx_bits_left = 1) then

          case r_state is

            when tx_id =>

              r_state        <= tx_ctrl;
              r_tx_shift     <= left_align(c_ctrl_hdr & std_logic_vector(r_mailbox_dlc));
              r_tx_bits_left <= c_ctrl_bits;

            when tx_ctrl =>

              v_data_bits := data_bits(r_mailbox_dlc);

              if (v_data_bits = 0) then
                r_state        <= tx_crc;
                r_tx_bits_left <= c_crc_bits;
              else
                r_state        <= tx_data;
                r_tx_shift     <= std_logic_vector(shift_left(unsigned(r_mailbox_data),
                                                              to_integer(c_max_data_bits - v_data_bits)));
                r_tx_bits_left <= v_data_bits;
              end if;

            when tx_data =>

              r_state        <= tx_crc;
              r_tx_bits_left <= c_crc_bits;

            when tx_crc =>

              r_state        <= tx_ack;
              r_tx_bits_left <= c_ack_bits;

            when tx_ack =>

              r_state        <= tx_eof;
              r_tx_bits_left <= c_eof_bits;

            when others =>

              -- End of EOF or of the error flag: p_bus_monitor times the rest
              r_state <= idle;

          end case;

        end if;
      end if;
    end if;

  end process p_tx_fsm;

  w_crc_field <= '1' when (r_state = tx_id or r_state = tx_ctrl or r_state = tx_data) else
                 '0';

  w_stuffed_field <= '1' when (w_crc_field = '1' or r_state = tx_crc) else
                     '0';

  w_flag_level <= '1' when (w_error_passive = '1') else
                  '0';

  w_next_bit <= r_tx_shift(63) when (w_crc_field = '1') else
                r_crc_reg(14) when (r_state = tx_crc) else
                w_flag_level when (r_state = tx_error_flag and r_tx_bits_left > 1) else
                '1';

  w_send_bit <= w_bit_tick and not (w_stuff_insert or r_arb_lost or r_bit_error or w_ack_missing);

  w_frame_done <= '1' when (r_state = tx_eof and w_send_bit = '1' and r_tx_bits_left = 1) else
                  '0';

  w_flag_done <= '1' when (r_state = tx_error_flag and w_send_bit = '1' and r_tx_bits_left = 1) else
                 '0';

  -- ========================================================================
  -- 6. BIT MONITOR: Compare each bit sent with the bus at the sample point
  -- ========================================================================
  -- Reading dominant on a recessive bit is lost arbitration in the ID and
  -- RTR bits and the ACK in the ACK slot. Any other mismatch is a bit error,
  -- and each of these takes effect on the next bit boundary.
  -- ========================================================================
  w_frame_active <= '1' when (r_state /= idle and r_state /= tx_error_flag) else
                    '0';

  w_ack_missing <= '1' when (w_frame_active = '1' and r_cur_ack = '1' and r_ack_seen = '0') else
                   '0';

  w_arb_fail <= w_bit_tick and r_arb_lost;
  w_tx_fail  <= w_bit_tick and (r_bit_error or w_ack_missing);

  p_bit_monitor : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (w_tx_clear = '1' or w_bit_tick = '1') then
        r_arb_lost        <= '0';
        r_bit_error       <= '0';
        r_arb_stuff_error <= '0';
        r_ack_seen        <= '0';
      elsif (w_sample_tick = '1' and w_frame_active = '1' and r_rx /= r_tx_pin) then
        if (r_tx_pin = '0') then
          r_bit_error <= '1';
        elsif (r_cur_ack = '1') then
          r_ack_seen <= '1';
        elsif (r_cur_arb = '0') then
          r_bit_error <= '1';
        elsif (r_cur_stuff = '0') then
          r_arb_lost <= '1';
        else
          r_bit_error       <= '1';
          r_arb_stuff_error <= '1';
        end if;
      end if;

      if (w_tx_clear = '1') then
        r_cur_arb   <= '0';
        r_cur_stuff <= '0';
        r_cur_ack   <= '0';
      elsif (w_bit_tick = '1') then
        r_cur_stuff <= w_stuff_insert;

        if (r_state = tx_id) then
          r_cur_arb <= '1';
        else
          r_cur_arb <= '0';
        end if;

        if (r_state = tx_ack and r_tx_bits_left = 2 and w_stuff_insert = '0') then
          r_cur_ack <= '1';
        else
          r_cur_ack <= '0';
        end if;
      end if;
    end if;

  end process p_bit_monitor;

  -- ========================================================================
  -- 7. BIT STUFFING: Insert opposite polarity after 5 consecutive same bits
  -- ========================================================================
  -- The check runs before each bit, so a run ending on the last CRC bit is
  -- still followed by a stuff bit. The fixed-form tail bits are never counted.
  -- ========================================================================
  w_stuff_insert <= '1' when (r_stuff_count = c_stuff_run) else
                    '0';

  p_stuffing : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (w_tx_clear = '1') then
        r_stuff_count <= (others => '0');
        r_tx_pin      <= '1';
      elsif (w_tx_start = '1') then
        r_stuff_count <= to_unsigned(1, 3);
        r_tx_pin      <= '0';                                                  -- SOF (dominant)
      elsif (w_arb_fail = '1') then
        r_stuff_count <= (others => '0');
        r_tx_pin      <= '1';
      elsif (w_tx_fail = '1') then
        r_stuff_count <= (others => '0');
        r_tx_pin      <= w_flag_level;
      elsif (r_state /= idle and w_bit_tick = '1') then
        if (w_stuff_insert = '1') then
          -- The stuff bit also starts the next run of identical bits
          r_tx_pin      <= not r_tx_pin;
          r_stuff_count <= to_unsigned(1, 3);
        else
          r_tx_pin <= w_next_bit;

          if (w_stuffed_field = '0') then
            r_stuff_count <= (others => '0');
          elsif (w_next_bit = r_tx_pin) then
            r_stuff_count <= r_stuff_count + 1;
          else
            r_stuff_count <= to_unsigned(1, 3);
          end if;
        end if;
      end if;
    end if;

  end process p_stuffing;

  -- ========================================================================
  -- 8. CRC-15 CALCULATION (polynomial 0x4599 = 100_0101_1001_1001)
  -- ========================================================================
  -- Covers SOF to the end of the data field, unstuffed: the dominant SOF
  -- leaves the zero start value unchanged. Shifting then sends the finished
  -- CRC out, MSB first.
  -- ========================================================================
  p_crc : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (w_tx_clear = '1' or r_state = idle) then
        r_crc_reg <= (others => '0');
      elsif (w_send_bit = '1') then
        if (w_crc_field = '1' and (w_next_bit xor r_crc_reg(14)) = '1') then
          r_crc_reg <= (r_crc_reg(13 downto 0) & '0') xor c_crc_poly;
        else
          r_crc_reg <= r_crc_reg(13 downto 0) & '0';
        end if;
      end if;
    end if;

  end process p_crc;

  -- ========================================================================
  -- 9. FAULT CONFINEMENT: ISO 11898-1 transmit error counter
  -- ========================================================================
  -- Each failed frame adds 8 and each good one takes away 1. At 128 the error
  -- flag turns recessive so the node cannot jam the bus, and at 256 it stops
  -- transmitting. Two failures do not count: a dominant reading on a recessive
  -- stuff bit before RTR, and a missing ACK while error passive when nothing
  -- on the bus answers the flag, so a node alone on a bus cannot reach bus-off.
  -- ========================================================================
  w_error_passive <= '1' when (r_tec >= c_tec_passive) else
                     '0';

  w_count_error <= not (r_uncounted or (r_ack_error and w_error_passive and not r_flag_dominant));

  p_fault_confinement : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_tec           <= (others => '0');
        r_bus_off       <= '0';
        r_ack_error     <= '0';
        r_uncounted     <= '0';
        r_flag_dominant <= '0';
      else
        if (w_tx_fail = '1') then
          r_ack_error     <= w_ack_missing;
          r_uncounted     <= r_arb_stuff_error;
          r_flag_dominant <= '0';
        elsif (r_state = tx_error_flag and w_sample_tick = '1' and r_rx = '0') then
          r_flag_dominant <= '1';
        end if;

        if (w_frame_done = '1' and r_tec > 0) then
          r_tec <= r_tec - 1;
        elsif (w_flag_done = '1' and w_count_error = '1') then
          r_tec <= r_tec + c_tec_step;

          if (r_tec + c_tec_step >= c_tec_bus_off) then
            r_bus_off <= '1';
          end if;
        end if;
      end if;
    end if;

  end process p_fault_confinement;

  -- ========================================================================
  -- 10. TX OUTPUT: Drive CAN pin with safety gate
  -- ========================================================================
  -- Combinational, so the pin goes recessive without waiting for a clock.
  -- p_tx_fsm then abandons the frame, so it cannot resume when the gate
  -- returns. Receivers reject the cut-off frame on its stuff error.
  -- ========================================================================
  can_tx_o <= r_tx_pin when (bus_ok_i = '1' and rst_n_i = '1') else
              '1';

  -- Busy flag for diagnostics: a frame is in the mailbox or on the bus
  w_busy <= '1' when (r_state /= idle or r_mailbox_full = '1') else
            '0';

  can_busy_o <= w_busy;

  can_status_o(10)         <= r_bus_off;
  can_status_o(9)          <= w_error_passive;
  can_status_o(8 downto 0) <= std_logic_vector(r_tec);

  -- ========================================================================
  -- 11. REGISTER READS: STATUS
  -- ========================================================================
  -- The bus acknowledges every access at once, so read data has to be ready in
  -- the cycle after the strobe. It is zero at all other times, which lets the
  -- top level OR the peripherals together.
  -- ========================================================================
  p_read : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      r_rdata <= (others => '0');

      if (rst_n_i = '1' and bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '0' and
          bus_i.addr = c_can_status_addr) then
        r_rdata(16 downto 8) <= std_logic_vector(r_tec);
        r_rdata(2)           <= r_bus_off;
        r_rdata(1)           <= w_error_passive;
        r_rdata(0)           <= w_busy;
      end if;
    end if;

  end process p_read;

  rdata_o <= r_rdata;

  -- ========================================================================
  -- 12. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
  -- ========================================================================
  -- Property: CAN TX forced recessive when safety gate drops
  -- Property: CAN TX recessive while no frame is in progress
  -- Property: No more than 5 identical bits in the stuffed fields
  -- Property: Mailbox only loaded when bus_ok asserted
  -- Property: A bus-off node stays off the bus
  -- ========================================================================
  p_formal_asserts : process (clk_i) is

    variable v_full_prev : std_logic;
    variable v_gate_prev : std_logic;

  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        v_full_prev := '0';
      else
        -- Property: TX forced recessive when safety gate drops
        if (bus_ok_i = '0') then
          assert can_tx_o = '1'
            report "FORMAL FAIL: CAN TX not recessive on safety gate drop"
            severity error;
        end if;

        -- Property: TX recessive while idle
        if (r_state = idle) then
          assert can_tx_o = '1'
            report "FORMAL FAIL: CAN TX not recessive while idle"
            severity error;
        end if;

        -- Property: A stuff bit always ends a run of 5
        assert r_stuff_count <= c_stuff_run
          report "FORMAL FAIL: CAN stuff run too long"
          severity error;

        -- Property: Mailbox only loaded when bus_ok asserted
        if (r_mailbox_full = '1' and v_full_prev = '0') then
          assert v_gate_prev = '1'
            report "FORMAL FAIL: CAN mailbox loaded with safety gate low"
            severity error;
        end if;

        -- Property: A bus-off node stays off the bus
        if (r_bus_off = '1') then
          assert can_tx_o = '1'
            report "FORMAL FAIL: CAN TX not recessive while bus-off"
            severity error;
        end if;

        v_full_prev := r_mailbox_full;
      end if;

      v_gate_prev := bus_ok_i;
    end if;

  end process p_formal_asserts;

end architecture rtl;
