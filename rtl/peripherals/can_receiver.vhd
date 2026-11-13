-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  CAN Receiver
-- Module Name:  can_receiver - rtl
-- Description:  Follows every frame on the bus, base or extended, data or
--               remote. It removes stuff bits, checks the CRC and the fixed-form
--               bits, acknowledges good frames, and signals errors with an error
--               flag, counting them as ISO 11898-1 asks.
--
--               It follows the node's own frames too, so that a node which loses
--               arbitration is already at the right point in the winner's frame.
--               While the node is transmitting it only listens: the transmitter
--               has its own bit monitor and answers for the frame.
--
--               It does not send overload frames. A dominant bit in the
--               intermission just puts off the next frame, which is what an
--               overload flag from another node needs from a receiver.
--
-- Traces to:    TSR_CAN_002
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity can_receiver is
  port (
    clk_i   : in    std_logic;
    rst_n_i : in    std_logic;

    -- The bus, and the bit timing, from the controller
    -- Synchronised
    rx_i          : in    std_logic;
    sample_tick_i : in    std_logic;
    bit_tick_i    : in    std_logic;
    -- At least 10 recessive bits have gone by
    sof_allowed_i : in    std_logic;

    -- The state of the node
    -- Reset, gate down or bus-off: stay off the bus
    clear_i         : in    std_logic;
    transmitting_i  : in    std_logic;
    tx_failed_i     : in    std_logic;
    error_passive_i : in    std_logic;

    -- Dominant for an ACK or an active error flag
    pin_o : out   std_logic;

    -- Between a SOF and the end of the frame or flag, where edges mean something else
    in_frame_o  : out   std_logic;
    flag_done_o : out   std_logic;

    -- Receive error counter
    rec_o : out   unsigned(7 downto 0);

    -- A good frame from another node, for one clock. With an 11-bit identifier
    -- in the low bits of id_o, or 29 bits if ide_o is set.
    frame_valid_o : out   std_logic;
    id_o          : out   std_logic_vector(28 downto 0);
    rtr_o         : out   std_logic;
    ide_o         : out   std_logic;
    dlc_o         : out   unsigned(3 downto 0);
    -- First byte in 63:56
    data_o : out   std_logic_vector(63 downto 0)
  );
end entity can_receiver;

architecture rtl of can_receiver is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_CAN_002";

  constant c_stuff_run : unsigned(2 downto 0)  := to_unsigned(5, 3);
  constant c_crc_poly  : unsigned(14 downto 0) := to_unsigned(16#4599#, 15);
  constant c_flag_bits : unsigned(2 downto 0)  := to_unsigned(6, 3);
  constant c_rec_good  : unsigned(7 downto 0)  := to_unsigned(127, 8);
  constant c_rec_step  : unsigned(7 downto 0)  := to_unsigned(8, 8);
  constant c_rec_limit : unsigned(7 downto 0)  := to_unsigned(255, 8);

  -- The field that the next sampled bit belongs to

  type t_field is (
    -- Outside a frame, until the next SOF
    field_wait,
    field_id,
    -- RTR, or SRR in an extended frame
    field_rtr,
    field_ide,
    field_ext_id,
    field_ext_rtr,
    field_r1,
    field_r0,
    field_dlc,
    field_data,
    field_crc,
    field_crc_delim,
    field_ack,
    field_ack_delim,
    field_eof,
    -- An error flag, sent by p_pin
    field_flag
  );

  signal r_field : t_field;
  signal r_count : unsigned(6 downto 0);

  -- The fields that bit stuffing covers, and the run of identical bits so far
  signal w_stuffed   : std_logic;
  signal w_stuff_bit : std_logic;
  signal r_run       : unsigned(2 downto 0);
  signal r_last      : std_logic;

  -- Run through the CRC field as well, so that a good frame leaves zero
  signal r_crc      : unsigned(14 downto 0);
  signal w_crc_good : std_logic;

  -- The frame so far
  signal r_id   : std_logic_vector(28 downto 0);
  signal r_rtr  : std_logic;
  signal r_ide  : std_logic;
  signal r_dlc  : unsigned(3 downto 0);
  signal r_data : std_logic_vector(63 downto 0);

  -- Errors
  signal r_bad_bit      : std_logic;
  signal r_after_flag   : std_logic;
  signal r_flag_stepped : std_logic;
  signal r_frame_valid  : std_logic;
  signal w_flag_end     : std_logic;
  signal r_flag_left    : unsigned(2 downto 0);
  signal r_rec          : unsigned(7 downto 0);

  -- Bus output
  signal r_pin : std_logic;

  -- Data field length in bits: DLC values above 8 still carry 8 bytes

  function data_bits (
    dlc : unsigned(3 downto 0)
  ) return unsigned is
  begin

    if (dlc > 8) then
      return to_unsigned(64, 7);
    end if;

    return resize(dlc, 4) & "000";

  end function data_bits;

begin

  -- ========================================================================
  -- 1. FRAME FIELDS
  -- ========================================================================
  -- The check for a stuff bit comes before each bit, so one that follows the
  -- last CRC bit is found in the CRC delimiter's place.
  -- ========================================================================
  w_stuffed <= '1' when (r_field = field_id or r_field = field_rtr or r_field = field_ide or
                          r_field = field_ext_id or r_field = field_ext_rtr or r_field = field_r1 or
                          r_field = field_r0 or r_field = field_dlc or r_field = field_data or
                          r_field = field_crc or (r_field = field_crc_delim and r_run = c_stuff_run)) else
               '0';

  w_stuff_bit <= '1' when (w_stuffed = '1' and r_run = c_stuff_run) else
                 '0';

  w_crc_good <= '1' when (r_crc = 0) else
                '0';

  w_flag_end <= '1' when (bit_tick_i = '1' and r_field = field_flag and r_flag_left = 0) else
                '0';

  p_fields : process (clk_i) is

    variable v_bad : boolean;
    variable v_dlc : unsigned(3 downto 0);

  begin

    if rising_edge(clk_i) then
      r_bad_bit      <= '0';
      r_frame_valid  <= '0';
      r_flag_stepped <= '0';

      if (clear_i = '1' or tx_failed_i = '1') then
        r_field      <= field_wait;
        r_after_flag <= '0';
        r_count      <= (others => '0');
        r_run        <= (others => '0');
        r_last       <= '1';
        r_crc        <= (others => '0');
      elsif (w_flag_end = '1') then
        r_field      <= field_wait;
        r_after_flag <= '1';
      elsif (sample_tick_i = '1') then
        v_bad := false;

        if (w_stuff_bit = '1') then
          -- The complement of the run it ends, and part of no field
          v_bad  := rx_i = r_last;
          r_last <= rx_i;
          r_run  <= to_unsigned(1, 3);
        else
          if (w_stuffed = '1') then
            r_last <= rx_i;

            if (rx_i = r_last) then
              r_run <= r_run + 1;
            else
              r_run <= to_unsigned(1, 3);
            end if;

            if ((rx_i xor r_crc(14)) = '1') then
              r_crc <= (r_crc(13 downto 0) & '0') xor c_crc_poly;
            else
              r_crc <= r_crc(13 downto 0) & '0';
            end if;
          end if;

          r_count <= r_count + 1;

          case r_field is

            when field_wait =>

              -- A dominant bit straight after an error flag counts against this node
              if (r_after_flag = '1') then
                r_after_flag   <= '0';
                r_flag_stepped <= not rx_i;
              end if;

              if (rx_i = '0' and sof_allowed_i = '1') then
                -- SOF: a dominant bit, which leaves the CRC at zero
                r_field <= field_id;
                r_count <= (others => '0');
                r_run   <= to_unsigned(1, 3);
                r_last  <= '0';
                r_crc   <= (others => '0');
                r_id    <= (others => '0');
                r_rtr   <= '0';
                r_ide   <= '0';
                r_dlc   <= (others => '0');
                r_data  <= (others => '0');
              end if;

            when field_id =>

              r_id <= r_id(27 downto 0) & rx_i;

              if (r_count = 10) then
                r_field <= field_rtr;
              end if;

            when field_rtr =>

              r_rtr   <= rx_i;
              r_field <= field_ide;

            when field_ide =>

              r_ide <= rx_i;

              if (rx_i = '1') then
                r_field <= field_ext_id;
                r_count <= (others => '0');
              else
                r_field <= field_r0;
              end if;

            when field_ext_id =>

              r_id <= r_id(27 downto 0) & rx_i;

              if (r_count = 17) then
                r_field <= field_ext_rtr;
              end if;

            when field_ext_rtr =>

              r_rtr   <= rx_i;
              r_field <= field_r1;

            when field_r1 =>

              r_field <= field_r0;

            when field_r0 =>

              r_field <= field_dlc;
              r_count <= (others => '0');

            when field_dlc =>

              v_dlc := r_dlc(2 downto 0) & rx_i;
              r_dlc <= v_dlc;

              if (r_count = 3) then
                r_count <= (others => '0');

                if (r_rtr = '1' or v_dlc = 0) then
                  r_field <= field_crc;
                else
                  r_field <= field_data;
                end if;
              end if;

            when field_data =>

              r_data(63 - to_integer(r_count)) <= rx_i;

              if (r_count = data_bits(r_dlc) - 1) then
                r_field <= field_crc;
                r_count <= (others => '0');
              end if;

            when field_crc =>

              if (r_count = 14) then
                r_field <= field_crc_delim;
              end if;

            when field_crc_delim =>

              v_bad   := rx_i = '0';
              r_field <= field_ack;

            when field_ack =>

              -- An ACK that this node sent has to be on the bus
              v_bad   := r_pin = '0' and rx_i = '1';
              r_field <= field_ack_delim;

            when field_ack_delim =>

              -- A CRC error waits until here, so that it is not signalled in a
              -- part of the frame where it might be taken for something else
              v_bad   := rx_i = '0' or w_crc_good = '0';
              r_field <= field_eof;
              r_count <= (others => '0');

            when field_eof =>

              if (r_count < 6) then
                v_bad := rx_i = '0';
              end if;

              -- The frame counts from here. A dominant last bit does not undo it.
              if (r_count = 5 and rx_i = '1' and transmitting_i = '0') then
                r_frame_valid <= '1';
              end if;

              if (r_count = 6) then
                r_field <= field_wait;
              end if;

            when others =>

              null;

          end case;

        end if;

        if (v_bad) then
          if (transmitting_i = '1') then
            r_field <= field_wait;
          else
            r_field   <= field_flag;
            r_bad_bit <= '1';
          end if;
        end if;
      end if;
    end if;

  end process p_fields;

  in_frame_o  <= '0' when (r_field = field_wait) else
                 '1';
  flag_done_o <= w_flag_end;

  -- ========================================================================
  -- 2. BUS OUTPUT: The ACK and error flags
  -- ========================================================================
  -- These change on a bit boundary, and r_field has moved on by then: it is
  -- field_ack on the boundary between the CRC delimiter and the ACK slot.
  -- ========================================================================
  p_pin : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (clear_i = '1' or tx_failed_i = '1') then
        r_pin       <= '1';
        r_flag_left <= c_flag_bits;
      elsif (r_bad_bit = '1') then
        r_flag_left <= c_flag_bits;
      elsif (bit_tick_i = '1') then
        r_pin <= '1';

        if (r_field = field_ack and w_crc_good = '1' and transmitting_i = '0') then
          r_pin <= '0';
        elsif (r_field = field_flag and r_flag_left /= 0) then
          r_pin       <= error_passive_i;
          r_flag_left <= r_flag_left - 1;
        end if;
      end if;
    end if;

  end process p_pin;

  pin_o <= r_pin;

  -- ========================================================================
  -- 3. FAULT CONFINEMENT: ISO 11898-1 receive error counter
  -- ========================================================================
  -- Each error a receiver finds adds 1, and a dominant bit straight after its
  -- error flag adds 8, because this node was then the first to complain. Each
  -- good frame takes away 1, or brings the count back from above 127.
  -- ========================================================================
  p_rec : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_rec <= (others => '0');
      elsif (r_flag_stepped = '1') then
        if (r_rec > c_rec_limit - c_rec_step) then
          r_rec <= c_rec_limit;
        else
          r_rec <= r_rec + c_rec_step;
        end if;
      elsif (r_bad_bit = '1') then
        if (r_rec /= c_rec_limit) then
          r_rec <= r_rec + 1;
        end if;
      elsif (r_frame_valid = '1') then
        if (r_rec > c_rec_good) then
          r_rec <= c_rec_good;
        elsif (r_rec /= 0) then
          r_rec <= r_rec - 1;
        end if;
      end if;
    end if;

  end process p_rec;

  rec_o <= r_rec;

  -- ========================================================================
  -- 4. THE FRAME
  -- ========================================================================
  frame_valid_o <= r_frame_valid;
  id_o          <= r_id;
  rtr_o         <= r_rtr;
  ide_o         <= r_ide;
  dlc_o         <= r_dlc;
  data_o        <= r_data;

  -- ========================================================================
  -- 5. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
  -- ========================================================================
  -- Property: Nothing is driven while the node has to stay off the bus
  -- Property: A frame is only delivered with a good CRC
  -- Property: The stuff run never passes 5
  -- ========================================================================
  p_formal_asserts : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '1') then
        if (r_frame_valid = '1') then
          assert w_crc_good = '1'
            report "FORMAL FAIL: CAN frame delivered with a bad CRC"
            severity error;
        end if;

        assert r_run <= c_stuff_run
          report "FORMAL FAIL: CAN receive run too long"
          severity error;
      end if;
    end if;

  end process p_formal_asserts;

end architecture rtl;
