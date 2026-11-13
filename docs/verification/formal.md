# Formal verification (roadmap R2.1)

First formal checks of the blocks that decide whether a request may have an
effect: the lockstep comparator, the bus response fabric, and the comparator
in front of the ECC RAM's store commit. Each is a SymbiYosys job with a prove
task, a cover task and a deliberately broken RTL that the prove task must
reject.

## How it runs

```bash
pip install -r sim/requirements-formal.txt     # YoWASP Yosys and SymbiYosys, z3
python sim/scripts/run_formal.py --broken      # all jobs; writes sim/formal/build/results.*
```

1. GHDL synthesises the VHDL block to Verilog (`ghdl --synth --out=verilog`).
   The RTL is not changed for the proof. Internal signals that a property needs,
   such as the comparator's state register and the RAM's commit strobe, are
   brought out with Yosys's `expose` pass.
2. The RTL's own clocked "FORMAL FAIL" assertions, which GHDL 6 keeps as
   `$fatal` calls, are removed from the netlist. They are simulation checks that
   assume a reset first; the harnesses restate them without that assumption.
   GHDL 6 also names record fields as escaped identifiers (`us_i[addr]`)
   where GHDL 4.1, which CI uses, writes `bus_i_addr`. The driver rewrites the
   first form into the second, and the harnesses use it, so the same jobs run
   on either version. All three prove and cover on both.
3. SymbiYosys runs `smtbmc` with z3:
   - **prove**: k-induction. PASS is a proof for every depth, not a bounded
     result.
   - **cover**: every `cover` statement must be reached, which shows that the
     antecedent of each assertion can happen. A property whose antecedent is
     unreachable proves nothing.
4. With `--broken`, the same prove task runs on a copy of the RTL with one
   deliberate break, and must fail. This checks that the harness is connected
   to the logic it claims to check.

CI runs all three jobs with `--broken` in the `formal` job of `ci.yml`.

## Assumptions

Every job uses the same model:

- one clock, and every input free in every cycle: both cores' buses, the fatal
  input, the slaves' read data, and the cold and warm resets
- every register starts from any value, so illegal state encodings are covered
  from the first cycle without modelling how they arise
- in `store_commit`, the RAM array also starts from any value, so any stored
  word, including an uncorrectable one, can be read

No assumption constrains the buses or the resets. The proofs are of the RTL as
GHDL synthesises it. They say nothing about a mapped netlist (roadmap R3.1),
about clock-domain crossings (below), or about the CPUs.

## Jobs and properties

### `lockstep_comparator` (`fv_lockstep_comparator.sv`)

| ID | Property | Requirement |
|----|----------|-------------|
| CMP-01 | Nothing the cores disagree on, and nothing during a fatal fault, reaches the system bus | TSR_LOCKSTEP_001, HSI BUS-01 |
| CMP-02 | A passed cycle is core A's, from a healthy state | TSR_LOCKSTEP_001 |
| CMP-03 | A closed gate drives a quiet bus | HSR_LOCKSTEP_005 |
| CMP-04 | The gate is closed exactly when the state is not healthy, and then the fault is reported and the safe state held | HSI FLT-03 |
| CMP-05 | An illegal encoding is reported at once | HSI FLT-03, TSR_SAFETY_GATE_001 |
| CMP-06 | The comparator's own fault output never shows less than the registered one | HSI FLT-01 |
| CMP-07 | A mismatch or fatal fault sampled out of reset is latched and reported at the next edge | HSR_LOCKSTEP_003 |
| CMP-08 | Only a reset clears a fault | HSI FLT-04 |
| CMP-09 | Any state that is not healthy moves to the tripped encoding | TSR_SAFETY_GATE_001 |
| CMP-10 | A reset sampled at an edge leaves the comparator healthy | TSR_RESET_001 |
| CMP-11 | The registered fault output is a function of registers alone | HSI FLT-01 |

Broken RTL: the fault output of revision 1.0, which reads only the latch. The
proof fails on CMP-04, CMP-05 and CMP-11.

### `soc_bus_fabric` (`fv_soc_bus_fabric.sv`)

The harness decodes the address map from HSI BUS-02 itself, rather than
reusing the RTL's decode.

| ID | Property | Requirement |
|----|----------|-------------|
| BUS-P1 | Never ACK and ERR together | HSI BUS-04 |
| BUS-P2 | A reset in the response cycle stops the response | HSI BUS-11 |
| BUS-P3 | No data with ERR | HSI BUS-04 |
| BUS-P4 | An accepted request gets exactly one of ACK and ERR in the next cycle, and nothing else gets either | HSI BUS-03, BUS-04, TSR_BUS_001 |
| BUS-P5 | ERR exactly for an unmapped address, or a RAM block access with an uncorrectable word | HSI BUS-08, BUS-09 |
| BUS-P6 | A load gets the addressed slave's data only, and a store gets none | HSI BUS-03, BUS-07 |

Broken RTL: unmapped addresses acknowledged, as in revision 1.0. The proof
fails on BUS-P5.

### `store_commit` (`fv_store_commit.sv`)

The comparator in front of the ECC RAM, as `top_automotive_soc` wires them.
The RAM is cut to 16 words (`g_addr_bits = 4`). The logic around the array is
the same at any size.

| ID | Property | Requirement |
|----|----------|-------------|
| COM-01 | A commit only with the gate open, the word correctable and the warm reset released | HSI BUS-05, TSR_SAFETY_GATE_002 |
| COM-02 | A closed gate commits nothing, whatever is pending | TSR_SAFETY_GATE_002 |
| COM-03 | A commit belongs to a store that the comparator passed in the cycle before, out of reset, which both cores made identically | TSR_LOCKSTEP_001 (compare before side effect) |
| COM-04 | A store the cores disagree on never commits | TSR_LOCKSTEP_001 |

Broken RTL: the commit ignores the gate. The proof fails on COM-01 and COM-02.

## Result

Run on 2026-11-13, from the tree of this commit:

| Tool | Version |
|------|---------|
| GHDL | 6.0.0 (`6.0.0.r0.ge589c698c`), mcode |
| Yosys | 0.71 (YoWASP `yowasp-yosys` 0.71.0.0.post1285) |
| SymbiYosys | YoWASP, same package |
| z3 | 5.4.1 (`z3-solver` 5.4.1.0) |

| Job | Prove | Cover | Broken RTL | Time |
|-----|-------|-------|------------|------|
| lockstep_comparator | PASS (proof) | PASS, 6 of 6 reached | Rejected | 5 s |
| soc_bus_fabric | PASS (proof) | PASS, 8 of 8 reached | Rejected | 4 s |
| store_commit | PASS (proof) | PASS, 4 of 4 reached | Rejected | 15 s |

## What the proof found

The first run of `lockstep_comparator` failed CMP-04 and CMP-06 at step 0.
With the state register at `FAULT_TRIPPED` and the fault latch at 0, the
comparator's own `nmi_fault_o`, which the startup self-test reads, was 0. Only
an upset of the latch bit can reach that state, so simulation from a reset
never did. The mirror case, a latch set with a healthy state, reported a fault
while the bus stayed open.

The fix makes either bit enough. `nmi_fault_o` now includes the registered
fault, and a set latch moves a healthy state to `FAULT_TRIPPED` at the next
edge. Two simulation tests in `tb_lockstep_illegal_state` reproduce both cases.
They failed on the earlier RTL and pass now, and two mutants keep them in force.

## Not yet covered

| Item | Status |
|------|--------|
| Clock-domain crossings (watchdog kick and status handshakes) | Planned as a separate multiclock proof with named clock assumptions |
| Comparator self-test sequencer | Planned with R2.4 |
| Temporal-diversity delay line | Simulation only (`tb_temporal_diversity`, `tb_soc_lockstep`) |
| Full-size RAM, CPUs, top level | Out of scope for these proofs |
