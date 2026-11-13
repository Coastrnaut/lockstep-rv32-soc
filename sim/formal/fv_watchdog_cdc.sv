// ============================================================================
// Formal harness: the watchdog's clock-domain crossings (roadmap R2.1)
// ============================================================================
// watchdog_supervisor as the SoC uses it: the bus on clk_i, the watchdog on
// wd_clk_i, and two handshakes between them, a kick request into the watchdog
// and a status word out of it.
//
// Assumptions:
// - Two clocks, unrelated: in every step of the solver's global clock each one
//   may rise, fall or stay, as long as each changes at least once in three
//   steps. Either may run up to three times faster than the other, in any phase.
//   SymbiYosys's multiclock mode.
// - Metastability is not modelled. A synchroniser flip-flop takes the value its
//   input had before the edge. A two-flop synchroniser's resolution is a timing
//   property of the netlist (roadmap R3.1), not of this RTL.
// - Both resets are low in the first step and released together at a free
//   moment after each clock has had an edge in reset, then stay released: the
//   properties are about crossings during operation. Registers start from any
//   value, as after power-up.
// - The bus and the gate are free in every step. The watchdog's counter is
//   not constrained.
// The handshakes' internal registers are brought out with Yosys's expose pass.
// ============================================================================

module fv_watchdog_cdc (
  input        clk_i,
  input        wd_clk_i,
  input        rst_release,
  input [31:0] addr, data,
  input [3:0]  sel,
  input        we, valid, bus_ok
);

  (* gclk *) reg gclk;

  // ------------------------------------------------------------------------
  // Reset: low at the start, released once, never asserted again
  // ------------------------------------------------------------------------
  reg released = 1'b0;
  always @(posedge gclk) if (rst_release) released <= 1'b1;
  wire rst_n = released;

  wire [31:0] rdata;
  wire        sys_reset;
  wire        kick_req, kick_pulse, status_req, status_toggle;
  wire [1:0]  kick_ack, status_ack, status_sync;
  wire [2:0]  kick_sync;
  wire [9:0]  status_wd, status_sys;

  watchdog_supervisor dut (
    .clk_i(clk_i), .rst_n_i(rst_n),
    .bus_i_addr(addr), .bus_i_data(data), .bus_i_sel(sel), .bus_i_we(we), .bus_i_valid(valid),
    .bus_ok_i(bus_ok), .rdata_o(rdata),
    .wd_clk_i(wd_clk_i), .wd_rst_n_i(rst_n),
    .sys_reset_o(sys_reset),
    .r_kick_req(kick_req), .r_kick_ack(kick_ack), .r_kick_sync(kick_sync), .w_kick(kick_pulse),
    .r_status_req(status_req), .r_status_ack(status_ack), .r_status_sync(status_sync),
    .r_status_toggle(status_toggle), .r_status_wd(status_wd), .r_status_sys(status_sys)
  );

  // Clock edges, seen from the global clock
  reg clk_q = 1'b0, wd_q = 1'b0;
  always @(posedge gclk) begin
    clk_q <= clk_i;
    wd_q  <= wd_clk_i;
  end
  wire clk_rise = clk_i && !clk_q;
  wire wd_rise  = wd_clk_i && !wd_q;

  // ------------------------------------------------------------------------
  // Kicks. The watchdog samples the kick at its clock edge, so what it gets is
  // the kick as it was in the step before the edge. A request raised while
  // the handshake is idle is "owed"; any request at all makes one kick
  // "allowed". The supervisor merges a kick made while another is crossing,
  // by design: real kicks are 40,000 watchdog clocks apart.
  // ------------------------------------------------------------------------
  reg  kick_req_q = 1'b0, kick_q = 1'b0, kick_last = 1'b0;
  reg       owed = 1'b0;
  reg [1:0] allowed = 2'd0;
  wire      idle      = !kick_req && kick_ack == 2'b00 && kick_sync == 3'b000;
  wire      delivered = wd_rise && kick_q;
  wire      rose      = kick_req && !kick_req_q;
  // The handshake was idle in the step before
  reg  idle_from = 1'b0;
  always @(posedge gclk) begin
    kick_req_q <= kick_req;
    kick_q     <= kick_pulse;
    idle_from  <= idle;
    if (wd_rise) kick_last <= kick_q;
    if (!rst_n) begin
      owed    <= 1'b0;
      allowed <= 2'd0;
    end else begin
      // Requests not yet delivered, saturating
      if (rose && !delivered && allowed != 2'd3) allowed <= allowed + 2'd1;
      if (delivered && !rose && allowed != 2'd0) allowed <= allowed - 2'd1;
      if (rose && idle_from) owed <= 1'b1;
      else if (delivered) owed <= 1'b0;
    end
  end

  // ------------------------------------------------------------------------
  // Status: the bus side's clock edges since r_status_wd last changed,
  // saturating at 3
  // ------------------------------------------------------------------------
  reg [9:0] status_wd_q;
  reg [1:0] settled = 2'd0;
  always @(posedge gclk) begin
    status_wd_q <= status_wd;
    if (status_wd != status_wd_q) settled <= 2'd0;
    else if (clk_rise && settled != 2'd3) settled <= settled + 2'd1;
  end
  reg  status_ready_q = 1'b0;
  always @(posedge gclk) status_ready_q <= (status_ack[1] == status_req);
  // The bus side takes the word at a clock edge, deciding on the values from
  // before the edge, as its flip-flops do
  wire status_load = rst_n && clk_rise && status_ready_q;

  reg past_valid = 1'b0;
  always @(posedge gclk) past_valid <= 1'b1;

  // A kick has crossed since the reset, for the covers
  reg kick_went = 1'b0;
  always @(posedge gclk) if (!rst_n) kick_went <= 1'b0; else if (delivered) kick_went <= 1'b1;

  // Initial reset: the first step is in reset, and the reset is released only
  // after both clocks have had an edge in it. In the SoC each reset comes out
  // of a synchroniser, which needs its own clock to release it.
  reg saw_clk = 1'b0, saw_wd = 1'b0;
  always @(posedge gclk) if (past_valid && !released) begin
    if (clk_rise) saw_clk <= 1'b1;
    if (wd_rise)  saw_wd  <= 1'b1;
  end
  always @* if (!past_valid) assume (!released && !saw_clk && !saw_wd);
  always @* if (!released) assume (!rst_release || (saw_clk && saw_wd));

  // Both clocks keep running: each changes level at least once in every three
  // steps, so either may run up to three times faster than the other, in any
  // phase. Without this, k-induction never closes (a stopped clock can stretch
  // any trace). A stopped clock does nothing at its edges, so it cannot break
  // these safety properties in a way a slow one could not.
  reg [1:0] clk_still = 2'd0, wd_still = 2'd0;
  always @(posedge gclk) begin
    clk_still <= (clk_i != clk_q) ? 2'd0 : clk_still + 2'd1;
    wd_still  <= (wd_clk_i != wd_q) ? 2'd0 : wd_still + 2'd1;
  end
  always @* assume (clk_still != 2'd3 && wd_still != 2'd3);

  // A synchronous reset acts at the first clock edge after it is seen, which
  // can fall in the step it is released in, so the checks start a step later
  always @(posedge gclk) if (past_valid && rst_n && $past(rst_n)) begin
    // CDC-01 (TSR_WD_001, HSI 8.4): no kick reaches the watchdog that the bus
    // side did not request, so one request is never counted twice
    if (delivered) assert (allowed != 2'd0 || rose);
    // Helper invariants for the induction: a request on its way through the
    // synchronisers, not yet merged with an earlier one, has been counted
    if (kick_req && !kick_sync[0]) assert (allowed != 2'd0 || rose);
    if (kick_sync[0] && !kick_sync[1]) assert (allowed != 2'd0 || rose);
    if (kick_pulse) assert (allowed != 2'd0 || rose);
    // CDC-02: none is lost. A request raised while the handshake was idle has
    // reached the watchdog by the time the handshake is idle again
    if (idle) assert (!owed);
    // Helper invariant for the induction: a kick owed is still on its way, as
    // the request, the kick into the watchdog, or the kick it is about to take
    // and has not passed the last synchroniser stage, except in the step it
    // is taken
    if (owed) assert (kick_req || kick_pulse || kick_q);
    if (owed) assert (kick_sync[2] == 1'b0 || delivered);
    // CDC-03: the kick into the watchdog is one watchdog clock wide
    if (wd_rise) assert (!(kick_q && kick_last));
    // CDC-04 (Rule CD-02, bundled data): the bus side takes the status word only
    // after it has been still for two of its clocks, the synchroniser's settling
    // time, so it never takes a word in the middle of a change
    if (status_load) assert (settled >= 2'd2 && status_wd == status_wd_q);
    // Helper invariants for the induction: each stage of the bus side's
    // synchroniser that has caught up with the answer to the current request
    // has taken a clock edge since the word changed (the counter counts an edge
    // a step late)
    // The status handshake is a ring: the request goes through the watchdog
    // side's synchroniser to the toggle, and back through the bus side's to the
    // ack. A new request starts only when the ack has caught up, so along the
    // ring the values are the request's for a prefix and the old one after it
    if (status_sync[0] != status_req) assert (status_sync[1] != status_req && status_toggle != status_req &&
                                              status_ack[0] != status_req && status_ack[1] != status_req);
    if (status_sync[1] != status_req) assert (status_toggle != status_req && status_ack[0] != status_req &&
                                              status_ack[1] != status_req);
    if (status_toggle != status_req) assert (status_ack[0] != status_req && status_ack[1] != status_req);
    if (status_ack[0] != status_req) assert (status_ack[1] != status_req);
    if (status_toggle == status_req && status_ack[0] == status_toggle && status_ack[1] != status_toggle)
      assert (settled >= 2'd1 || clk_rise);
    if (status_toggle == status_req && status_ack[0] == status_toggle && status_ack[1] == status_toggle)
      assert (settled >= 2'd2 || (settled == 2'd1 && clk_rise));
    // CDC-05: the watchdog side changes the status word only while the bus side
    // is not about to take it: the request it answers has crossed, and the
    // word is the one it reports
    if (status_wd != $past(status_wd)) assert (status_toggle != $past(status_toggle));
    // CDC-06: the reset into the SoC comes from a watchdog-clock flip-flop. It
    // changes only at a watchdog clock edge, so it cannot glitch
    if (sys_reset != $past(sys_reset)) assert ($past(wd_rise) || wd_rise);
  end

  // Reachability of each antecedent above
  always @(posedge gclk) if (past_valid && rst_n) begin
    cover (delivered);                                     // a kick crosses
    cover (owed && !idle);                                 // one is owed while it crosses
    cover (idle && $past(!idle) && kick_went);             // and the handshake ends
    cover (status_load && $past(status_sys) != status_wd_q); // a new word is taken
    cover (status_wd != $past(status_wd));                 // the watchdog side changes it
    cover (sys_reset);                                     // the watchdog resets the SoC
  end

endmodule
