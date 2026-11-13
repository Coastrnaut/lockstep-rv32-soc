-- ============================================================================
-- Company:      Open-Source Automotive SoC Initiative
-- Design Name:  System Bus Response Fabric
-- Module Name:  soc_bus_fabric - rtl
-- Description:  Ends every request that the lockstep comparator accepts with
--               exactly one response, from the slave it was addressed to
--               (HSI section 8.1).
--
--                 Acceptance edge: the gated system bus carries a strobe, and
--                                  the warm reset is released. The target is
--                                  decoded and registered with the request.
--                 Response cycle:  the next one. ACK with that slave's read
--                                  data, or ERR with zero data for an unmapped
--                                  address or an uncorrectable RAM word.
--
--               A request the comparator stops never reaches this block, and
--               gets no response from it: the core's own bus timeout ends it.
--
--               The response carries the read data's parity, taken from each
--               slave's data before the selection and selected separately, so
--               that a fault in the data's path from here to either core does
--               not reach both cores unseen (HSI 8.6).
--
-- Traces to:    TSR_BUS_001, TSR_BUS_002
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library lockstep;
  use lockstep.package_soc_types.all;

entity soc_bus_fabric is
  generic (
    -- RAM size in 64-bit words, as ecc_data_ram's g_addr_bits
    g_ram_addr_bits : positive range 4 to 15 := 15
  );
  port (
    clk_i : in    std_logic;
    -- Warm reset: clears the response pending
    rst_n_i : in    std_logic;

    -- The gated system bus, after the comparator
    bus_i : in    t_rv_bus;

    -- What each slave answers in the response cycle, zero when not read
    ram_rdata_i  : in    std_logic_vector(c_data_width - 1 downto 0);
    wd_rdata_i   : in    std_logic_vector(c_data_width - 1 downto 0);
    can_rdata_i  : in    std_logic_vector(c_data_width - 1 downto 0);
    uart_rdata_i : in    std_logic_vector(c_data_width - 1 downto 0);

    -- An uncorrectable word in the response cycle of a RAM access
    ram_fatal_i : in    std_logic;

    -- The response, to core A now and to core B two clocks later
    rsp_o : out   t_bus_rsp
  );
end entity soc_bus_fabric;

architecture rtl of soc_bus_fabric is

  -- ISO 26262 Automated Traceability Attributes
  attribute requirement_id : string;
  attribute requirement_id of rtl : architecture is "TSR_BUS_001, TSR_BUS_002";

  -- One-hot target of the accepted request

  subtype t_target is std_logic_vector(4 downto 0);

  -- SRAM and the ECC registers
  constant c_tgt_ram  : natural := 0;
  constant c_tgt_wd   : natural := 1;
  constant c_tgt_can  : natural := 2;
  constant c_tgt_uart : natural := 3;

  -- Unmapped
  constant c_tgt_none : natural := 4;

  type t_addresses is array (natural range <>) of std_logic_vector(c_addr_width - 1 downto 0);

  constant c_ecc_regs : t_addresses :=
  (
    c_ecc_sbe_count_addr,
    c_ecc_dbe_count_addr,
    c_ecc_syndrome_addr,
    c_ecc_status_addr,
    c_ecc_first_info_addr,
    c_ecc_first_addr_addr,
    c_ecc_first_time_addr,
    c_ecc_patrol_addr
  );

  constant c_wd_regs : t_addresses :=
  (
    c_wd_kick_addr,
    c_wd_status_addr,
    c_wd_reset_src_addr
  );

  constant c_can_regs : t_addresses :=
  (
    c_can_id_addr,
    c_can_dlc_addr,
    c_can_data_addr,
    c_can_status_addr,
    c_can_data_hi_addr,
    c_can_tx_request_addr,
    c_can_rx_id_addr,
    c_can_rx_info_addr,
    c_can_rx_data_addr,
    c_can_rx_data_hi_addr,
    c_can_rx_status_addr,
    c_can_rx_irq_en_addr
  );

  constant c_uart_regs : t_addresses :=
  (
    c_uart_tx_data_addr,
    c_uart_status_addr,
    c_uart_parity_addr
  );

  -- Is addr in the same word as one of the registers?

  function in_word_of (
    addr : std_logic_vector;
    regs : t_addresses
  ) return boolean is
  begin

    loop_i : for lv_i in regs'range loop

      if (addr(c_addr_width - 1 downto 2) = regs(lv_i)(c_addr_width - 1 downto 2)) then
        return true;
      end if;

    end loop loop_i;

    return false;

  end function in_word_of;

  function decode (
    addr : std_logic_vector
  ) return t_target is

    variable v_target : t_target;

  begin

    v_target := (others => '0');

    if (addr(c_addr_width - 1 downto g_ram_addr_bits + 3) =
        c_ram_base_addr(c_addr_width - 1 downto g_ram_addr_bits + 3) or in_word_of(addr, c_ecc_regs)) then
      v_target(c_tgt_ram) := '1';
    elsif (in_word_of(addr, c_wd_regs)) then
      v_target(c_tgt_wd) := '1';
    elsif (in_word_of(addr, c_can_regs)) then
      v_target(c_tgt_can) := '1';
    elsif (in_word_of(addr, c_uart_regs)) then
      v_target(c_tgt_uart) := '1';
    else
      v_target(c_tgt_none) := '1';
    end if;

    return v_target;

  end function decode;

  -- The accepted request, held for its response cycle
  signal r_pending : std_logic;
  signal r_we      : std_logic;
  signal r_target  : t_target;

  signal w_ack   : std_logic;
  signal w_err   : std_logic;
  signal w_rdata : std_logic_vector(c_data_width - 1 downto 0);
  signal w_rpar  : std_logic;

begin

  -- ========================================================================
  -- 1. ACCEPTED REQUEST CONTEXT
  -- ========================================================================
  -- Captured at the acceptance edge, before any response is chosen. The warm
  -- reset drops a request that it catches, so nothing answers it.
  -- ========================================================================
  p_accept : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        r_pending <= '0';
        r_we      <= '0';
        r_target  <= (others => '0');
      else
        r_pending <= bus_i.valid;
        r_we      <= bus_i.we;
        r_target  <= decode(bus_i.addr);
      end if;
    end if;

  end process p_accept;

  -- ========================================================================
  -- 2. THE RESPONSE
  -- ========================================================================
  -- Exactly one of ACK and ERR, and only in the cycle after an accepted request.
  -- A reset that arrives in that cycle also stops the response.
  -- ========================================================================
  w_err <= '1' when (r_pending = '1' and rst_n_i = '1' and
                      (r_target(c_tgt_none) = '1' or (r_target(c_tgt_ram) = '1' and ram_fatal_i = '1'))) else
           '0';

  w_ack <= '1' when (r_pending = '1' and rst_n_i = '1' and w_err = '0') else
           '0';

  -- Only the addressed slave's read data, and none with ERR or for a store
  p_select : process (all) is
  begin

    w_rdata <= (others => '0');

    if (w_ack = '1' and r_we = '0') then
      if (r_target(c_tgt_ram) = '1') then
        w_rdata <= ram_rdata_i;
      elsif (r_target(c_tgt_wd) = '1') then
        w_rdata <= wd_rdata_i;
      elsif (r_target(c_tgt_can) = '1') then
        w_rdata <= can_rdata_i;
      elsif (r_target(c_tgt_uart) = '1') then
        w_rdata <= uart_rdata_i;
      end if;
    end if;

  end process p_select;

  -- The same choice for the parity, made apart from the data's: each slave's
  -- data is reduced to its parity before it is chosen, so that the data's
  -- selection and everything after it are checked against this
  p_parity : process (all) is
  begin

    w_rpar <= '0';

    if (w_ack = '1' and r_we = '0') then
      if (r_target(c_tgt_ram) = '1') then
        w_rpar <= xor ram_rdata_i;
      elsif (r_target(c_tgt_wd) = '1') then
        w_rpar <= xor wd_rdata_i;
      elsif (r_target(c_tgt_can) = '1') then
        w_rpar <= xor can_rdata_i;
      elsif (r_target(c_tgt_uart) = '1') then
        w_rpar <= xor uart_rdata_i;
      end if;
    end if;

  end process p_parity;

  rsp_o.rdata <= w_rdata;
  rsp_o.rpar  <= w_rpar;
  rsp_o.ack   <= w_ack;
  rsp_o.err   <= w_err;

  -- ========================================================================
  -- 3. FORMAL VERIFICATION ASSERTIONS (ISO 26262 §5.3)
  -- ========================================================================
  -- Property: ACK and ERR never together
  -- Property: No response without an accepted request
  -- Property: ERR carries no data
  -- Property: The target is one-hot
  -- ========================================================================
  p_formal_asserts : process (clk_i) is
  begin

    if rising_edge(clk_i) then
      assert not (w_ack = '1' and w_err = '1')
        report "FORMAL FAIL: ACK and ERR together"
        severity error;

      if (r_pending = '0') then
        assert w_ack = '0' and w_err = '0'
          report "FORMAL FAIL: response with no request accepted"
          severity error;
      end if;

      if (w_err = '1') then
        assert unsigned(w_rdata) = 0
          report "FORMAL FAIL: read data with ERR"
          severity error;
      end if;

      if (r_pending = '1') then
        assert r_target = "00001" or r_target = "00010" or r_target = "00100" or
               r_target = "01000" or r_target = "10000"
          report "FORMAL FAIL: response target not one-hot"
          severity error;
      end if;
    end if;

  end process p_formal_asserts;

end architecture rtl;
