-- ============================================================================
-- Testbench support: Independent CAN receiver node
-- ============================================================================
-- Listens to the bus like any other node and shares no logic with the RTL. It
-- samples 75% into each bit on its own timing from the SOF edge, as real nodes
-- do, removes and checks stuff bits, recomputes the CRC, and pulls the ACK slot
-- dominant for a good frame. It gives up on a frame at the first stuff error
-- and sends no error flags.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.can_test_pkg.all;

entity can_test_node is
  generic (
    g_bit_time : time
  );
  port (
    bus_i        : in    std_logic; -- The wired-AND bus
    dut_tx_i     : in    std_logic; -- Sampled alongside the bus for frame_o.wire
    ack_enable_i : in    std_logic;
    ack_o        : out   std_logic; -- Dominant in the ACK slot of a good frame
    frame_o      : out   t_rx_frame;
    starts_o     : out   natural;   -- SOFs seen on the bus
    done_o       : out   natural    -- Frames finished or given up on
  );
end entity can_test_node;

architecture tb of can_test_node is

begin

  p_receiver : process is

    variable v_frame  : t_rx_frame;
    variable v_crc    : std_logic_vector(14 downto 0);
    variable v_run    : natural;
    variable v_last   : std_logic;
    variable v_bit    : std_logic;
    variable v_starts : natural;
    variable v_done   : natural;
    variable v_in_sof : boolean;

    procedure sample_bus (
      variable sampled : out std_logic
    ) is
    begin

      sampled                           := bus_i;
      v_frame.wire(v_frame.wire_length) := dut_tx_i;
      v_frame.wire_length               := v_frame.wire_length + 1;

    end procedure sample_bus;

    procedure next_wire_bit (
      variable sampled : out std_logic
    ) is
    begin

      wait for g_bit_time;
      sample_bus(sampled);

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

    -- Called at the sample point of the SOF bit

    procedure receive_frame is

      variable v_bytes : natural;

    begin

      v_frame := c_empty_frame;
      sample_bus(v_bit);
      v_crc   := crc15_next((others => '0'), v_bit);
      v_last  := v_bit;
      v_run   := 1;

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

      -- The ACK slot starts one and a quarter bits from now
      if (ack_enable_i = '1' and v_frame.crc = v_frame.crc_expected) then
        ack_o <= '0' after g_bit_time * 5 / 4, '1' after g_bit_time * 9 / 4;
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

      -- A dominant third intermission bit is the next SOF
      v_in_sof := v_bit = '0';

    end procedure receive_frame;

  begin

    ack_o <= '1';

    loop

      if (not v_in_sof) then
        wait until bus_i = '0';
        wait for g_bit_time * 3 / 4;
      end if;

      v_in_sof := false;

      -- A glitch that has gone by the sample point is not a SOF
      if (bus_i = '0') then
        v_starts := v_starts + 1;
        starts_o <= v_starts;
        receive_frame;
        v_done   := v_done + 1;
        done_o   <= v_done;
        frame_o  <= v_frame;
      end if;

    end loop;

  end process p_receiver;

end architecture tb;
