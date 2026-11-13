// ============================================================================
// Formal harness: lockstep_comparator (roadmap R2.1)
// ============================================================================
// The comparator comes from sim/formal/run_formal.py as Verilog that GHDL
// synthesised from rtl/safety_blocks/lockstep_comparator.vhd. Its state
// register is brought out with Yosys's expose pass, so the RTL is unchanged.
//
// Assumptions: one clock, and every input is free in every cycle: both buses,
// the fatal input and the reset. The registers start from any value, so the
// proof covers illegal state encodings from the first cycle without modelling
// how they arise. Nothing else is assumed.
// ============================================================================

module fv_lockstep_comparator (
  input        clk_i,
  input        rst_n,
  input [31:0] a_addr, b_addr,
  input [31:0] a_data, b_data,
  input [3:0]  a_sel, b_sel,
  input        a_we, b_we,
  input        a_valid, b_valid,
  input        fatal
);

  wire        nmi, fault, safe, bus_valid;
  wire [31:0] s_addr, s_data;
  wire [3:0]  s_sel;
  wire        s_we, s_valid;
  wire [7:0]  state;
  wire        latched;

  lockstep_comparator dut (
    .clk_i(clk_i), .rst_n_syn_i(rst_n),
    .\core_a_bus_i[addr] (a_addr), .\core_a_bus_i[data] (a_data), .\core_a_bus_i[sel] (a_sel),
    .\core_a_bus_i[we] (a_we), .\core_a_bus_i[valid] (a_valid),
    .\core_b_bus_i[addr] (b_addr), .\core_b_bus_i[data] (b_data), .\core_b_bus_i[sel] (b_sel),
    .\core_b_bus_i[we] (b_we), .\core_b_bus_i[valid] (b_valid),
    .fatal_fault_i(fatal),
    .nmi_fault_o(nmi), .fault_o(fault), .safe_state_o(safe), .bus_valid_o(bus_valid),
    .\sys_bus_o[addr] (s_addr), .\sys_bus_o[data] (s_data), .\sys_bus_o[sel] (s_sel),
    .\sys_bus_o[we] (s_we), .\sys_bus_o[valid] (s_valid),
    .r_current_state(state), .r_fault_latched(latched)
  );

  localparam [7:0] OK = 8'h5A, TRIPPED = 8'hA5;

  wire mismatch = (a_addr != b_addr) || (a_data != b_data) || (a_sel != b_sel) ||
                  (a_we != b_we) || (a_valid != b_valid);
  wire legal    = (state == OK) || (state == TRIPPED);

  reg past_valid = 1'b0;
  always @(posedge clk_i) past_valid <= 1'b1;

  // --- Every cycle, whatever the state -------------------------------------
  always @* begin
    // CMP-01: nothing the cores disagree on, and nothing during a fatal fault,
    // reaches the system bus
    if (mismatch || fatal) assert (!s_valid);
    // CMP-02: a passed cycle is core A's, from a healthy state
    if (s_valid) assert (state == OK && a_valid && s_addr == a_addr && s_data == a_data &&
                         s_sel == a_sel && s_we == a_we);
    // CMP-03: a closed gate drives a quiet bus
    if (!bus_valid) assert (!s_valid && s_addr == 0 && s_data == 0 && s_sel == 0 && !s_we);
    // CMP-04 (HSI FLT-03): the gate is closed exactly when the state is not
    // healthy, and then the fault is reported and the safe state held, on both
    // fault outputs, whether the state is tripped or illegal
    assert (bus_valid == (state == OK));
    if (!bus_valid) assert (fault && nmi && safe);
    assert (safe == !bus_valid);
    // CMP-05: an illegal encoding is reported at once
    if (!legal) assert (fault && nmi && safe && !bus_valid && !s_valid);
    // CMP-06: the comparator's own fault output, which the self-test reads,
    // never shows less than the registered one
    if (fault) assert (nmi);
    // CMP-11 (HSI FLT-01): the registered fault output is a function of the
    // registers alone, so settling of the compare cannot reach the pin
    assert (fault == (latched || state != OK));
  end

  // --- Across one edge -------------------------------------------------------
  always @(posedge clk_i) if (past_valid) begin
    // CMP-07: a mismatch or fatal fault sampled out of reset is latched and
    // reported by the registered output at the next edge (HSR_LOCKSTEP_003)
    if ($past(rst_n) && ($past(mismatch) || $past(fatal)))
      assert (fault && !bus_valid && safe && state == TRIPPED);
    // CMP-08 (HSI FLT-04): only a reset clears a fault
    if ($past(rst_n) && $past(fault)) assert (fault && state == TRIPPED);
    // CMP-09: any state that is not healthy moves to the tripped encoding
    if ($past(rst_n) && !$past(legal)) assert (state == TRIPPED);
    // CMP-10: a reset sampled at an edge leaves the comparator healthy
    if (!$past(rst_n)) assert (state == OK && !fault && bus_valid && !safe);
  end

  // --- Reachability of each antecedent above -----------------------------------
  always @(posedge clk_i) if (past_valid) begin
    cover ($past(rst_n) && $past(mismatch) && !$past(fault));     // a fresh trip
    cover ($past(rst_n) && $past(fatal) && !$past(mismatch) && !$past(fault));
    cover (s_valid && s_we);                                        // a store passes
    cover ($past(rst_n) && !$past(legal) && state == TRIPPED);      // an illegal state handled
    cover ($past(rst_n) && $past(fault) && !$past(mismatch));       // a fault held with agreeing buses
    cover (!$past(rst_n) && $past(fault));                          // a reset clears a fault
  end

endmodule
