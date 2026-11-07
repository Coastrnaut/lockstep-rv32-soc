-- ============================================================================
-- Testbench support: What a CAN receiver saw on the bus
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

package can_test_pkg is

  -- Worst case: 98 stuffed bits, 24 stuff bits and a 13 bit tail
  constant c_max_frame_bits : positive := 135;

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
    stuff_error    : boolean;
    -- What the DUT drove, not the bus: one sample per wire bit from SOF
    wire        : std_logic_vector(0 to c_max_frame_bits - 1);
    wire_length : natural;
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
    stuff_error    => false,
    wire           => (others => '0'),
    wire_length    => 0
  );

  -- Shift-register sequence from the Bosch CAN 2.0 specification

  function crc15_next (
    crc      : std_logic_vector(14 downto 0);
    data_bit : std_logic
  ) return std_logic_vector;

end package can_test_pkg;

package body can_test_pkg is

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

end package body can_test_pkg;
