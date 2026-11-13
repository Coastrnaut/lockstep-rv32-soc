// ============================================================================
// Formal harness: soc_bus_fabric (roadmap R2.1, HSI section 8.1)
// ============================================================================
// The response contract, against a decode of HSI BUS-02 written here from the
// address map, not from the RTL. GHDL synthesises the fabric to Verilog first.
//
// Assumptions: one clock; the gated request, every slave's read data, the RAM
// fatal input and the warm reset are free in every cycle; the registers start
// from any value. The comparator in front is proved separately
// (fv_lockstep_comparator.sv).
// ============================================================================

module fv_soc_bus_fabric (
  input        clk_i,
  input        rst_n,
  input [31:0] addr,
  input [31:0] data,
  input [3:0]  sel,
  input        we,
  input        valid,
  input [31:0] ram_rdata, wd_rdata, can_rdata, uart_rdata,
  input        ram_fatal
);

  wire [31:0] rdata;
  wire        rpar, ack, err;

  soc_bus_fabric dut (
    .clk_i(clk_i), .rst_n_i(rst_n),
    .bus_i_addr(addr), .bus_i_data(data), .bus_i_sel(sel),
    .bus_i_we(we), .bus_i_valid(valid),
    .ram_rdata_i(ram_rdata), .wd_rdata_i(wd_rdata), .can_rdata_i(can_rdata),
    .uart_rdata_i(uart_rdata), .ram_fatal_i(ram_fatal),
    .rsp_o_rdata(rdata), .rsp_o_rpar(rpar), .rsp_o_ack(ack), .rsp_o_err(err)
  );

  // HSI BUS-02, from the address map: 0 unmapped, 1 RAM block, 2 watchdog,
  // 3 CAN, 4 UART
  function automatic [2:0] target (input [31:0] a);
    if (a[31:18] == 14'h0800)                           target = 3'd1; // SRAM 0x20000000-0x2003FFFF
    else if (a[31:5] == 27'h2000008)                    target = 3'd1; // ECC 0x40000100-0x4000011C
    else if (a[31:2] >= 30'h10000080 && a[31:2] <= 30'h10000082) target = 3'd2; // 0x40000200-208
    else if (a[31:2] >= 30'h100000C0 && a[31:2] <= 30'h100000CB) target = 3'd3; // 0x40000300-32C
    else if (a[31:2] >= 30'h10000100 && a[31:2] <= 30'h10000102) target = 3'd4; // 0x40000400-408
    else                                                target = 3'd0;
  endfunction

  reg past_valid = 1'b0;
  always @(posedge clk_i) past_valid <= 1'b1;

  // The request as the last edge sampled it
  reg        prev_rst_n, prev_valid, prev_we;
  reg [31:0] prev_addr;
  always @(posedge clk_i) begin
    prev_rst_n <= rst_n;
    prev_valid <= valid;
    prev_we    <= we;
    prev_addr  <= addr;
  end

  wire       accepted_before = past_valid && prev_rst_n && prev_valid;
  wire [2:0] tgt             = target(prev_addr);

  always @* begin
    // BUS-P1: never ACK and ERR together
    assert (!(ack && err));
    // BUS-P2: a reset in the response cycle stops the response
    if (!rst_n) assert (!ack && !err);
    // BUS-P3: no data with ERR
    if (err) assert (rdata == 0);
  end

  always @(posedge clk_i) if (past_valid) begin
    // BUS-P4 (BUS-04): an accepted request gets exactly one of ACK and ERR in
    // the next cycle, and nothing else gets either
    if (accepted_before && rst_n) assert (ack ^ err);
    if (!accepted_before) assert (!ack && !err);
    // BUS-P5 (BUS-08, BUS-09): ERR exactly for an unmapped address, or a RAM
    // block access with an uncorrectable word
    if (accepted_before && rst_n) assert (err == (tgt == 3'd0 || (tgt == 3'd1 && ram_fatal)));
    // BUS-P6 (BUS-03, BUS-07): a load gets the addressed slave's data only, and
    // a store gets none
    if (ack && prev_we) assert (rdata == 0);
    if (ack && !prev_we) begin
      if (tgt == 3'd1) assert (rdata == ram_rdata);
      if (tgt == 3'd2) assert (rdata == wd_rdata);
      if (tgt == 3'd3) assert (rdata == can_rdata);
      if (tgt == 3'd4) assert (rdata == uart_rdata);
    end
    // BUS-P7 (HSI 8.6, TSR_BUS_002): the parity is the addressed slave's own
    // data's, and 0 with no data. With BUS-P6 this makes the parity of the read
    // data even in every cycle. Stated per slave, because parity through a
    // multiplexer is hard for a SAT solver and this is the same fact.
    if (!(ack && !prev_we)) assert (!rpar);
    if (ack && !prev_we) begin
      if (tgt == 3'd1) assert (rpar == ^ram_rdata);
      if (tgt == 3'd2) assert (rpar == ^wd_rdata);
      if (tgt == 3'd3) assert (rpar == ^can_rdata);
      if (tgt == 3'd4) assert (rpar == ^uart_rdata);
    end
  end

  // Reachability of each antecedent above
  always @(posedge clk_i) if (past_valid) begin
    cover (ack && !prev_we && tgt == 3'd1);
    cover (ack && !prev_we && tgt == 3'd2);
    cover (ack && !prev_we && tgt == 3'd3);
    cover (ack && !prev_we && tgt == 3'd4);
    cover (ack && prev_we);
    cover (err && tgt == 3'd0);
    cover (err && tgt == 3'd1 && ram_fatal);
    cover (accepted_before && !rst_n);
  end

endmodule
