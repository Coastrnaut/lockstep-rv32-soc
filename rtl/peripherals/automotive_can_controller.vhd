-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Fault-Hardened CAN 2.0B Controller
-- Module Name:  automotive_can_controller - behavioral
-- Description:  Transmits CAN base-format data frames with bit-stuffing and
--               CRC-15, one bit every g_clks_per_bit clocks, and only while
--               the lockstep comparator validates the bus. An internal mailbox
--               buffers one outgoing frame.
--
--               Transmit only: can_rx_i is not monitored, so there is no
--               arbitration, ACK check, error signalling or retransmission.
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
    g_clks_per_bit : positive range 1 to 65535 := 100
  );
  port (
    clk_i   : in    std_logic;
    rst_n_i : in    std_logic;

    -- Internal bus from lockstep comparator (gated by safety)
    bus_i    : in    t_rv_bus;
    bus_ok_i : in    std_logic; -- Hardware transaction validation gate

    -- External CAN transceiver interface
    can_tx_o : out   std_logic;
    can_rx_i : in    std_logic;

    -- Diagnostic
    can_busy_o : out   std_logic
  );
end entity automotive_can_controller;

architecture rtl of automotive_can_controller is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_CAN_001";

  -- Frame field lengths in bits
  constant c_sof_bits      : unsigned(7 downto 0) := to_unsigned(1, 8);
  constant c_id_bits       : unsigned(7 downto 0) := to_unsigned(12, 8); -- ID + RTR
  constant c_ctrl_bits     : unsigned(7 downto 0) := to_unsigned(6, 8);  -- IDE + r0 + DLC
  constant c_max_data_bits : unsigned(7 downto 0) := to_unsigned(64, 8);
  constant c_crc_bits      : unsigned(7 downto 0) := to_unsigned(15, 8);
  constant c_ack_bits      : unsigned(7 downto 0) := to_unsigned(3, 8);  -- CRC delim, ACK slot, ACK delim
  constant c_eof_bits      : unsigned(7 downto 0) := to_unsigned(7, 8);
  constant c_ifs_bits      : unsigned(7 downto 0) := to_unsigned(4, 8);  -- 3 bits, then the tick ending them

  -- RTR, IDE and r0 are dominant: a data frame in base format
  constant c_dominant : std_logic_vector(0 downto 0) := "0";
  constant c_ctrl_hdr : std_logic_vector(1 downto 0) := "00";

  -- Bit stuffing: a complementary bit follows this many identical bits
  constant c_stuff_run : unsigned(2 downto 0) := to_unsigned(5, 3);

  -- CRC-15 generator polynomial
  constant c_crc_poly : unsigned(14 downto 0) := to_unsigned(16#4599#, 15);

  -- CAN frame state machine: the state names the field of the next bit to send

  type t_can_state is (
    idle,
    tx_sof,
    tx_id,
    tx_ctrl,
    tx_data,
    tx_crc,
    tx_ack,
    tx_eof,
    tx_interframe
  );

  signal r_state : t_can_state;

  -- Mailbox: holds one outgoing frame
  signal r_mailbox_id   : std_logic_vector(10 downto 0);
  signal r_mailbox_dlc  : unsigned(3 downto 0);
  signal r_mailbox_data : std_logic_vector(63 downto 0);
  signal r_mailbox_full : std_logic;

  -- Bit timing
  signal r_bit_cnt  : integer range 0 to g_clks_per_bit - 1;
  signal w_bit_tick : std_logic;

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

  -- Fields covered by the CRC and by bit stuffing
  signal w_crc_field     : std_logic;
  signal w_stuffed_field : std_logic;

  -- CRC-15 register
  signal r_crc_reg : unsigned(14 downto 0);

  -- Reset or a dropped safety gate clears the whole TX path at once
  signal w_tx_clear : std_logic;

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

  w_tx_clear <= '1' when (rst_n_i = '0' or bus_ok_i = '0') else
                '0';

  -- ========================================================================
  -- 1. MAILBOX LOAD: Accept data from internal bus when safety gate is clear
  -- ========================================================================
  -- A frame in progress keeps the mailbox full, so it cannot be overwritten.
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
      elsif (bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '1' and r_mailbox_full = '0') then
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
  -- 2. BIT TIMING: One tick per CAN bit while a frame is in progress
  -- ========================================================================
  p_bit_timer : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (w_tx_clear = '1' or r_state = idle) then
        r_bit_cnt <= 0;
      elsif (r_bit_cnt = 0) then
        r_bit_cnt <= g_clks_per_bit - 1;
      else
        r_bit_cnt <= r_bit_cnt - 1;
      end if;
    end if;

  end process p_bit_timer;

  w_bit_tick <= '1' when (r_state /= idle and r_bit_cnt = 0) else
                '0';

  -- ========================================================================
  -- 3. CAN TX STATE MACHINE
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
        if (r_mailbox_full = '1') then
          r_state        <= tx_sof;
          r_tx_shift     <= (others => '0');                                  -- SOF (dominant)
          r_tx_bits_left <= c_sof_bits;
        end if;
      elsif (w_send_bit = '1') then
        r_tx_shift     <= r_tx_shift(62 downto 0) & '0';
        r_tx_bits_left <= r_tx_bits_left - 1;

        if (r_tx_bits_left = 1) then

          case r_state is

            when tx_sof =>

              r_state        <= tx_id;
              r_tx_shift     <= left_align(r_mailbox_id & c_dominant);
              r_tx_bits_left <= c_id_bits;

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

            when tx_eof =>

              r_state        <= tx_interframe;
              r_tx_bits_left <= c_ifs_bits;

            when tx_interframe =>

              r_state <= idle;

            when others =>

              r_state <= idle;

          end case;

        end if;
      end if;
    end if;

  end process p_tx_fsm;

  w_crc_field <= '1' when (r_state = tx_sof or r_state = tx_id or r_state = tx_ctrl or r_state = tx_data) else
                 '0';

  w_stuffed_field <= '1' when (w_crc_field = '1' or r_state = tx_crc) else
                     '0';

  w_next_bit <= r_tx_shift(63) when (w_crc_field = '1') else
                r_crc_reg(14) when (r_state = tx_crc) else
                '1';

  w_send_bit <= w_bit_tick and not w_stuff_insert;

  w_frame_done <= '1' when (r_state = tx_interframe and w_send_bit = '1' and r_tx_bits_left = 1) else
                  '0';

  -- ========================================================================
  -- 4. BIT STUFFING: Insert opposite polarity after 5 consecutive same bits
  -- ========================================================================
  -- The check runs before each bit, so a run ending on the last CRC bit is
  -- still followed by a stuff bit. The fixed-form tail bits are never counted.
  -- ========================================================================
  w_stuff_insert <= '1' when (r_stuff_count = c_stuff_run) else
                    '0';

  p_stuffing : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (w_tx_clear = '1' or r_state = idle) then
        r_stuff_count <= (others => '0');
        r_tx_pin      <= '1';
      elsif (w_bit_tick = '1') then
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
  -- 5. CRC-15 CALCULATION (polynomial 0x4599 = 100_0101_1001_1001)
  -- ========================================================================
  -- Covers SOF to the end of the data field, unstuffed. Shifting then sends
  -- the finished CRC out, MSB first.
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
  -- 6. TX OUTPUT: Drive CAN pin with safety gate
  -- ========================================================================
  -- Combinational, so the pin goes recessive without waiting for a clock.
  -- p_tx_fsm then abandons the frame, so it cannot resume when the gate
  -- returns. Receivers reject the cut-off frame on its stuff error.
  -- ========================================================================
  can_tx_o <= r_tx_pin when (bus_ok_i = '1' and rst_n_i = '1') else
              '1';

  -- Busy flag for diagnostics
  can_busy_o <= '1' when r_state /= idle else
                '0';

  -- ========================================================================
  -- 7. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
  -- ========================================================================
  -- Property: CAN TX forced recessive when safety gate drops
  -- Property: CAN TX recessive while no frame is in progress
  -- Property: No more than 5 identical bits in the stuffed fields
  -- Property: Mailbox only loaded when bus_ok asserted
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

        v_full_prev := r_mailbox_full;
      end if;

      v_gate_prev := bus_ok_i;
    end if;

  end process p_formal_asserts;

end architecture rtl;
