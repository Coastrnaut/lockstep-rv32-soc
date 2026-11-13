-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  Watchdog Supervisor
-- Module Name:  watchdog_supervisor - rtl
-- Description:  Connects hardware_watchdog to the SoC. The bus and the watchdog
--               run on unrelated clocks, so everything that passes between them
--               goes through a handshake (Rule CD-02), and the watchdog keeps
--               working if clk_i stops.
--
--               A violation resets the SoC through sys_reset_o and then lets it
--               run again, with the watchdog counting from zero and the reason
--               held in RESET_SRC. This block takes only the cold reset, so that
--               RESET_SRC survives the reset it reports.
--
-- Traces to:    TSR_WD_001, TSR_SAFETY_GATE_003
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity watchdog_supervisor is
  port (
    -- System side
    clk_i : in    std_logic;
    -- Cold reset, synchronous to clk_i
    rst_n_i  : in    std_logic;
    bus_i    : in    t_rv_bus;
    bus_ok_i : in    std_logic;

    -- Register read data: valid the cycle after the strobe, otherwise zero
    rdata_o : out   std_logic_vector(c_data_width - 1 downto 0);

    -- Independent oscillator side
    wd_clk_i : in    std_logic;
    -- Cold reset, synchronous to wd_clk_i
    wd_rst_n_i : in    std_logic;

    -- High while the watchdog resets the SoC. Comes from a flip-flop, so it
    -- cannot glitch, and it is asynchronous to clk_i.
    sys_reset_o : out   std_logic
  );
end entity watchdog_supervisor;

architecture rtl of watchdog_supervisor is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_WD_001, TSR_SAFETY_GATE_003";

  -- Length of the reset pulse. It has to outlast a full trip through the status
  -- handshake, so that RESET_SRC is on the system side before the SoC restarts.
  constant c_reset_clocks : unsigned(4 downto 0) := to_unsigned(16, 5);

  -- RESET_SRC values
  constant c_src_early : std_logic_vector(1 downto 0) := "01";
  constant c_src_late  : std_logic_vector(1 downto 0) := "10";

  -- Status crossing to the system side: RESET_SRC in 9:8, watchdog status in 7:0

  subtype t_status is std_logic_vector(9 downto 0);

  -- Kick handshake
  signal w_kick_write : std_logic;
  signal r_kick_req   : std_logic;
  signal r_kick_ack   : std_logic_vector(1 downto 0);
  signal r_kick_sync  : std_logic_vector(2 downto 0);
  signal w_kick       : std_logic;

  -- Status handshake
  signal r_status_req    : std_logic;
  signal r_status_ack    : std_logic_vector(1 downto 0);
  signal r_status_sync   : std_logic_vector(1 downto 0);
  signal r_status_toggle : std_logic;
  signal r_status_wd     : t_status;
  signal r_status_sys    : t_status;

  -- Watchdog and the reset it causes
  signal w_wd_rst_n  : std_logic;
  signal w_violation : std_logic;
  signal w_wd_status : std_logic_vector(7 downto 0);
  signal r_reset     : std_logic;
  signal r_reset_cnt : unsigned(4 downto 0);
  signal r_reset_src : std_logic_vector(1 downto 0);
  signal r_rdata     : std_logic_vector(c_data_width - 1 downto 0);

begin

  -- ========================================================================
  -- 1. KICK: FROM THE BUS TO THE WATCHDOG
  -- ========================================================================
  -- The request stays up until the watchdog side has seen it, whatever the two
  -- clocks are doing. A kick made while one is still crossing counts as the same
  -- kick. Software that keeps kicking is still caught, by the next kick that
  -- crosses, which arrives early. A toggle would not do here: two quick kicks
  -- could put it back before the watchdog had seen it move, and lose them both.
  -- ========================================================================
  w_kick_write <= '1' when (bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '1' and bus_i.sel = "1111" and
                             bus_i.addr = c_wd_kick_addr and bus_i.data = c_wd_kick_key) else
                  '0';

  p_kick_request : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      r_kick_ack <= r_kick_ack(0) & r_kick_sync(1);

      if (rst_n_i = '0') then
        r_kick_req <= '0';
        r_kick_ack <= "00";
      elsif (w_kick_write = '1') then
        r_kick_req <= '1';
      elsif (r_kick_ack(1) = '1') then
        r_kick_req <= '0';
      end if;
    end if;

  end process p_kick_request;

  p_kick_sync : process (wd_clk_i) is
  begin

    if rising_edge(wd_clk_i) then
      if (wd_rst_n_i = '0') then
        r_kick_sync <= "000";
      else
        r_kick_sync <= r_kick_sync(1 downto 0) & r_kick_req;
      end if;
    end if;

  end process p_kick_sync;

  -- One clock wide, because a second clock of it would be an early kick
  w_kick <= r_kick_sync(1) and not r_kick_sync(2);

  -- ========================================================================
  -- 2. WATCHDOG, AND THE RESET IT CAUSES
  -- ========================================================================
  -- hardware_watchdog holds a violation until its own reset, and its reset
  -- output comes from comparators on the counter, so it can glitch. r_reset
  -- turns that into one clean pulse into the reset network, and then restarts
  -- the watchdog so that the SoC can run again.
  -- ========================================================================
  w_wd_rst_n <= wd_rst_n_i and not r_reset;

  i_watchdog : entity lockstep.hardware_watchdog
    port map (
      wd_clk_i    => wd_clk_i,
      rst_n_i     => w_wd_rst_n,
      cpu_kick_i  => w_kick,
      sys_reset_o => w_violation,
      wd_status_o => w_wd_status
    );

  p_reset_pulse : process (wd_clk_i) is
  begin

    if rising_edge(wd_clk_i) then
      if (wd_rst_n_i = '0') then
        r_reset     <= '0';
        r_reset_cnt <= (others => '0');
        r_reset_src <= "00";
      elsif (r_reset = '1') then
        r_reset_cnt <= r_reset_cnt + 1;

        if (r_reset_cnt = c_reset_clocks - 1) then
          r_reset     <= '0';
          r_reset_cnt <= (others => '0');
        end if;
      elsif (w_violation = '1') then
        r_reset <= '1';

        -- Bit 6 is the early violation. The late one is the only other cause.
        if (w_wd_status(6) = '1') then
          r_reset_src <= c_src_early;
        else
          r_reset_src <= c_src_late;
        end if;
      end if;
    end if;

  end process p_reset_pulse;

  -- With no oscillator r_reset never gets a clock edge, and wd_rst_n_i stays low.
  -- This keeps an unknown r_reset out of the reset network if that happens.
  sys_reset_o <= r_reset and wd_rst_n_i;

  -- ========================================================================
  -- 3. STATUS: FROM THE WATCHDOG TO THE BUS
  -- ========================================================================
  -- Several bits have to cross together, so the watchdog side copies them into
  -- r_status_wd and flips the handshake only once they are stable. They stay
  -- that way until the system side has taken them and asked for more. Software
  -- reads a copy that is a few watchdog clocks old, and both cores read the same
  -- one. It stops changing if the oscillator stops, which software can look for.
  --
  -- The request starts at 1, so that nothing is taken until the watchdog side has
  -- answered. Until then it has had no clock edge to reset it, and with a dead
  -- oscillator it never will.
  -- ========================================================================
  p_status_request : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      r_status_ack <= r_status_ack(0) & r_status_toggle;

      if (rst_n_i = '0') then
        r_status_req <= '1';
        r_status_ack <= "00";
        r_status_sys <= (others => '0');
      elsif (r_status_ack(1) = r_status_req) then
        r_status_sys <= r_status_wd;
        r_status_req <= not r_status_req;
      end if;
    end if;

  end process p_status_request;

  p_status_answer : process (wd_clk_i) is
  begin

    if rising_edge(wd_clk_i) then
      r_status_sync <= r_status_sync(0) & r_status_req;

      if (wd_rst_n_i = '0') then
        r_status_sync   <= "00";
        r_status_toggle <= '0';
        r_status_wd     <= (others => '0');
      elsif (r_status_sync(1) /= r_status_toggle) then
        r_status_wd     <= r_reset_src & w_wd_status;
        r_status_toggle <= r_status_sync(1);
      end if;
    end if;

  end process p_status_answer;

  -- ========================================================================
  -- 4. REGISTER READS: STATUS AND RESET_SRC
  -- ========================================================================
  p_read : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      r_rdata <= (others => '0');

      if (rst_n_i = '1' and bus_ok_i = '1' and bus_i.valid = '1' and bus_i.we = '0') then
        if (bus_i.addr = c_wd_status_addr) then
          r_rdata(7 downto 0) <= r_status_sys(7 downto 0);
        elsif (bus_i.addr = c_wd_reset_src_addr) then
          r_rdata(1 downto 0) <= r_status_sys(9 downto 8);
        end if;
      end if;
    end if;

  end process p_read;

  rdata_o <= r_rdata;

  -- ========================================================================
  -- 5. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
  -- ========================================================================
  -- Property: A violation the watchdog has latched is always being acted on
  -- Property: A reset pulse always has a reason recorded for it
  -- ========================================================================
  p_formal_asserts : process (wd_clk_i) is
  begin

    if rising_edge(wd_clk_i) then
      if (wd_rst_n_i = '1') then
        if (w_wd_status(7) = '1') then
          assert r_reset = '1'
            report "FORMAL FAIL: latched violation is not resetting the SoC"
            severity error;
        end if;
        if (r_reset = '1') then
          assert r_reset_src /= "00"
            report "FORMAL FAIL: reset pulse with no reason recorded"
            severity error;
        end if;
      end if;
    end if;

  end process p_formal_asserts;

end architecture rtl;
