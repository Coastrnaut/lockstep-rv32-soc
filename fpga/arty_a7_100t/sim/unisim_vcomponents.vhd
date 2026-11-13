-- ============================================================================
-- Stand-in for the UNISIM primitives that arty_a7_top uses, so that GHDL can
-- check the board wrapper without Vivado (fpga/arty_a7_100t/check_board.py).
-- Only the generics and ports the wrapper connects are declared. GHDL treats
-- the instances as black boxes. Vivado uses its own UNISIM library instead.
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;

package vcomponents is

  component mmcme2_base is
    generic (
      clkin1_period    : real    := 0.0;
      clkfbout_mult_f  : real    := 5.0;
      clkout0_divide_f : real    := 1.0;
      divclk_divide    : integer := 1
    );
    port (
      clkin1   : in    std_logic;
      clkfbin  : in    std_logic;
      clkfbout : out   std_logic;
      clkout0  : out   std_logic;
      locked   : out   std_logic;
      pwrdwn   : in    std_logic;
      rst      : in    std_logic
    );
  end component mmcme2_base;

  component startupe2 is
    generic (
      prog_usr      : string := "FALSE";
      sim_cclk_freq : real   := 0.0
    );
    port (
      cfgclk    : out   std_logic;
      cfgmclk   : out   std_logic;
      eos       : out   std_logic;
      preq      : out   std_logic;
      clk       : in    std_logic;
      gsr       : in    std_logic;
      gts       : in    std_logic;
      keyclearb : in    std_logic;
      pack      : in    std_logic;
      usrcclko  : in    std_logic;
      usrcclkts : in    std_logic;
      usrdoneo  : in    std_logic;
      usrdonets : in    std_logic
    );
  end component startupe2;

  component bufg is
    port (
      i : in    std_logic;
      o : out   std_logic
    );
  end component bufg;

end package vcomponents;
