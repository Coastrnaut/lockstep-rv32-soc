// ============================================================================
// Formal harness: compare before side effect at the RAM (roadmap R2.1)
// ============================================================================
// The real comparator in front of the real ECC RAM, as top_automotive_soc
// wires them: the RAM sees the gated system bus and the gate, and its
// uncorrectable-word output trips the comparator. The RAM is cut to 16 words
// (g_addr_bits = 4); the logic around the array is the same at any size.
//
// Assumptions: one clock; both cores' buses, the cold reset and the warm reset
// are free in every cycle; the registers start from any value, and so does the
// array, so any stored word, including an uncorrectable one, can be read.
// The commit strobe is brought out with Yosys's expose pass.
// ============================================================================

module fv_store_commit (
  input        clk_i,
  input        rst_cold_n,
  input        rst_warm_n,
  input [31:0] a_addr, b_addr,
  input [31:0] a_data, b_data,
  input [3:0]  a_sel, b_sel,
  input        a_we, b_we,
  input        a_valid, b_valid
);

  wire [31:0] s_addr, s_data, ram_rdata;
  wire [3:0]  s_sel;
  wire        s_we, s_valid, bus_valid, dbe, commit;
  wire        nmi, fault, safe;

  lockstep_comparator cmp (
    .clk_i(clk_i), .rst_n_syn_i(rst_cold_n),
    .core_a_bus_i_addr(a_addr), .core_a_bus_i_data(a_data), .core_a_bus_i_sel(a_sel),
    .core_a_bus_i_we(a_we), .core_a_bus_i_valid(a_valid),
    .core_b_bus_i_addr(b_addr), .core_b_bus_i_data(b_data), .core_b_bus_i_sel(b_sel),
    .core_b_bus_i_we(b_we), .core_b_bus_i_valid(b_valid),
    .fatal_fault_i(dbe),
    .nmi_fault_o(nmi), .fault_o(fault), .safe_state_o(safe), .bus_valid_o(bus_valid),
    .sys_bus_o_addr(s_addr), .sys_bus_o_data(s_data), .sys_bus_o_sel(s_sel),
    .sys_bus_o_we(s_we), .sys_bus_o_valid(s_valid)
  );

  ecc_data_ram ram (
    .clk_i(clk_i), .rst_n_i(rst_cold_n), .bus_rst_n_i(rst_warm_n),
    .bus_i_addr(s_addr), .bus_i_data(s_data), .bus_i_sel(s_sel),
    .bus_i_we(s_we), .bus_i_valid(s_valid),
    .bus_ok_i(bus_valid), .rdata_o(ram_rdata), .dbe_fatal_o(dbe),
    .w_commit(commit)
  );

  wire in_ram   = (s_addr[31:7] == 25'h0400000);   // 16 words of 8 bytes at 0x20000000
  wire mismatch = (a_addr != b_addr) || (a_data != b_data) || (a_sel != b_sel) ||
                  (a_we != b_we) || (a_valid != b_valid);

  reg past_valid = 1'b0;
  always @(posedge clk_i) past_valid <= 1'b1;

  always @* begin
    // COM-01 (BUS-05): a commit only with the gate open, the word correctable
    // and the warm reset released
    if (commit) assert (bus_valid && !dbe && rst_warm_n);
    // COM-02: a closed gate commits nothing, whatever is pending
    if (!bus_valid) assert (!commit);
  end

  always @(posedge clk_i) if (past_valid) begin
    // COM-03 (TSR_LOCKSTEP_001, compare before side effect): a commit belongs
    // to a store that the comparator passed in the cycle before, out of
    // reset, which both cores made identically
    if (commit) assert ($past(s_valid) && $past(s_we) && $past(!mismatch) && $past(in_ram) &&
                        $past(rst_cold_n) && $past(rst_warm_n));
    // COM-04: a store the cores disagree on never commits
    if ($past(mismatch)) assert (!commit);
  end

  // Reachability of each antecedent above
  always @(posedge clk_i) if (past_valid) begin
    cover (commit);
    cover ($past(s_valid && s_we && in_ram) && dbe);                   // a store finds an uncorrectable word
    cover ($past(a_valid && a_we && mismatch && bus_valid));           // a store the cores disagree on
    cover ($past(s_valid && s_we && in_ram && rst_warm_n) && !rst_warm_n); // a reset with a store pending
  end

endmodule
