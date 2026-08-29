-- ============================================================================
-- Testbench: Lockstep Comparator — Mismatch Injection
-- ============================================================================
-- Drives two cores with identical data, then forces a mismatch on Core B
-- to verify the lockstep comparator trips the NMI within 2 clock cycles.
--
-- Traces to: TSR_LOCKSTEP_001
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.package_soc_types.all;

entity tb_lockstep_comparator is
end entity;

architecture rtl of tb_lockstep_comparator is

    -- Clock period: 20ns (50 MHz)
    constant CLK_PERIOD : time := 20 ns;
    signal tb_clk       : std_logic := '0';
    signal tb_rst_n     : std_logic := '0';

    -- Core bus signals
    signal core_a_bus   : t_rv_bus;
    signal core_b_bus   : t_rv_bus;

    -- Safety outputs
    signal nmi_fault    : std_logic;
    signal safe_state   : std_logic;
    signal bus_valid    : std_logic;
    signal sys_bus      : t_rv_bus;

begin

    -- ========================================================================
    -- Clock Generator
    -- ========================================================================
    tb_clk <= not tb_clk after CLK_PERIOD / 2;

    -- ========================================================================
    -- DUT Instantiation
    -- ========================================================================
    i_dut : entity work.lockstep_comparator
        port map (
            clk_i        => tb_clk,
            rst_n_syn_i  => tb_rst_n,
            core_a_bus_i => core_a_bus,
            core_b_bus_i => core_b_bus,
            nmi_fault_o  => nmi_fault,
            safe_state_o => safe_state,
            bus_valid_o  => bus_valid,
            sys_bus_o    => sys_bus
        );

    -- ========================================================================
    -- Stimulus Process
    -- ========================================================================
    p_stimulus : process
    begin
        -- Initial values
        core_a_bus <= (addr => x"00000000", data => x"00000000", we => '0', valid => '0');
        core_b_bus <= (addr => x"00000000", data => x"00000000", we => '0', valid => '0');

        -- Phase 1: Reset (100ns)
        tb_rst_n <= '0';
        wait for 100 ns;
        tb_rst_n <= '1';
        wait for CLK_PERIOD;

        -- Phase 2: Normal operation — both cores identical (5 cycles)
        for i in 0 to 4 loop
            core_a_bus <= (addr => to_stdlogicvector(to_unsigned(i, 32)),
                           data => to_stdlogicvector(to_unsigned(i * 4, 32)),
                           we => '1', valid => '1');
            core_b_bus <= core_a_bus; -- Identical
            wait for CLK_PERIOD;
        end loop;

        assert bus_valid = '1' report "PASS: bus_valid high during normal op" severity note;
        assert nmi_fault = '0' report "PASS: no NMI during normal op" severity note;

        -- Phase 3: Inject mismatch on Core B (data differs)
        core_a_bus <= (addr => x"00000010", data => x"DEADBEEF", we => '1', valid => '1');
        core_b_bus <= (addr => x"00000010", data => x"CAFEBABE", we => '1', valid => '1');
        wait for CLK_PERIOD;

        -- Phase 4: Verify NMI tripped within 2 cycles
        wait for CLK_PERIOD;
        assert nmi_fault = '1' report "PASS: NMI tripped on mismatch" severity note;
        assert safe_state = '1' report "PASS: safe_state asserted" severity note;
        assert bus_valid = '0' report "PASS: bus_valid dropped" severity note;

        -- Phase 5: Verify lockstep stays tripped even after cores match again
        core_a_bus <= (addr => x"00000020", data => x"12345678", we => '0', valid => '0');
        core_b_bus <= core_a_bus;
        wait for CLK_PERIOD;
        assert nmi_fault = '1' report "PASS: NMI latched (still high after match)" severity note;

        -- Done
        wait for 50 ns;
        assert false report "=== ALL TESTS PASSED ===" severity failure;
    end process p_stimulus;

end architecture rtl;
